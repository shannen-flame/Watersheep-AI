import Combine
import Foundation
import UserNotifications

@MainActor
final class ReminderManager: ObservableObject {
    struct ReminderItem: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let createdAt: Date
        let dueDate: Date
        let sourceText: String
    }

    struct CreationResult {
        let reminder: ReminderItem
        let authorizationGranted: Bool
    }

    static let shared = ReminderManager()

    @Published private(set) var reminders: [ReminderItem] = []
    @Published private(set) var authorizationStatus = "Unknown"

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let storageKey = "watersheep.reminders"

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        loadReminders()

        Task {
            await refreshAuthorizationStatus()
        }
    }

    var upcomingReminders: [ReminderItem] {
        reminders
            .filter { $0.dueDate >= .now }
            .sorted { $0.dueDate < $1.dueDate }
    }

    func createReminder(from command: String) async throws -> CreationResult {
        let parsed = try parseReminderCommand(command)
        let granted = await requestAuthorizationIfNeeded()

        let reminder = ReminderItem(
            id: UUID(),
            title: parsed.title,
            createdAt: .now,
            dueDate: parsed.dueDate,
            sourceText: command
        )

        reminders.insert(reminder, at: 0)
        persistReminders()

        if granted {
            try await scheduleNotification(for: reminder)
        }

        print("Reminder created: \(reminder.title) at \(reminder.dueDate.formatted(date: Date.FormatStyle.DateStyle.abbreviated, time: Date.FormatStyle.TimeStyle.shortened))")
        return CreationResult(reminder: reminder, authorizationGranted: granted)
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = authorizationLabel(for: settings.authorizationStatus)
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationStatus = authorizationLabel(for: settings.authorizationStatus)
            return true
        case .denied:
            authorizationStatus = authorizationLabel(for: settings.authorizationStatus)
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                let updatedSettings = await center.notificationSettings()
                authorizationStatus = authorizationLabel(for: updatedSettings.authorizationStatus)
                return granted
            } catch {
                authorizationStatus = "Request Failed"
                return false
            }
        @unknown default:
            authorizationStatus = "Unknown"
            return false
        }
    }

    private func scheduleNotification(for reminder: ReminderItem) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Watersheep Reminder"
        content.body = reminder.title
        content.sound = .default

        let interval = max(reminder.dueDate.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.id.uuidString,
            content: content,
            trigger: trigger
        )

        try await center.add(request)
    }

    private func loadReminders() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let decoded = try? decoder.decode([ReminderItem].self, from: data) {
            reminders = decoded.sorted { $0.dueDate > $1.dueDate }
        }
    }

    private func persistReminders() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(reminders) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func authorizationLabel(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Authorized"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not Requested"
        @unknown default:
            return "Unknown"
        }
    }

    private func parseReminderCommand(_ command: String) throws -> (title: String, dueDate: Date) {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let lowercase = normalized.lowercased()
        let prefixes = [
            "remind me to ",
            "remind me ",
            "set a reminder to ",
            "set reminder to ",
        ]

        guard let prefix = prefixes.first(where: { lowercase.hasPrefix($0) }) else {
            throw ReminderError.unsupportedCommand
        }

        let body = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw ReminderError.emptyReminder
        }

        if let parsed = parseRelativeReminder(body) {
            return parsed
        }

        if let parsed = parseClockReminder(body) {
            return parsed
        }

        return (sanitizeReminderTitle(body), Date().addingTimeInterval(3600))
    }

    private func parseRelativeReminder(_ body: String) -> (title: String, dueDate: Date)? {
        let pattern = #"(?i)^(.*?)(?:\s+in\s+)(\d+)\s*(minute|minutes|hour|hours)$"#
        guard let match = body.firstMatch(of: pattern) else { return nil }

        let title = sanitizeReminderTitle(match[1])
        guard
            let quantity = Int(match[2]),
            !title.isEmpty
        else { return nil }

        let unit = match[3].lowercased()
        let interval: TimeInterval = unit.hasPrefix("hour") ? Double(quantity) * 3600 : Double(quantity) * 60
        return (title, Date().addingTimeInterval(interval))
    }

    private func parseClockReminder(_ body: String) -> (title: String, dueDate: Date)? {
        let patterns = [
            #"(?i)^(.*?)(?:\s+tomorrow at\s+)(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#,
            #"(?i)^(.*?)(?:\s+at\s+)(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#,
        ]

        for pattern in patterns {
            guard let match = body.firstMatch(of: pattern) else { continue }
            let title = sanitizeReminderTitle(match[1])
            guard !title.isEmpty, let hourValue = Int(match[2]) else { continue }

            let minuteValue = Int(match[3]) ?? 0
            let meridiem = match[4].lowercased()
            var hour = hourValue

            if meridiem == "pm", hour < 12 {
                hour += 12
            } else if meridiem == "am", hour == 12 {
                hour = 0
            }

            var dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            dateComponents.hour = hour
            dateComponents.minute = minuteValue

            var date = Calendar.current.date(from: dateComponents) ?? Date().addingTimeInterval(3600)
            if body.lowercased().contains("tomorrow at") {
                date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
            } else if date <= Date() {
                date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
            }

            return (title, date)
        }

        return nil
    }

    private func sanitizeReminderTitle(_ rawTitle: String) -> String {
        rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

enum ReminderError: LocalizedError {
    case unsupportedCommand
    case emptyReminder

    var errorDescription: String? {
        switch self {
        case .unsupportedCommand:
            return "That reminder format is not supported yet."
        case .emptyReminder:
            return "The reminder text is empty."
        }
    }
}

private extension String {
    func firstMatch(of pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range) else { return nil }

        return (0..<match.numberOfRanges).compactMap { index in
            let matchRange = match.range(at: index)
            guard let range = Range(matchRange, in: self) else { return "" }
            return String(self[range])
        }
    }
}
