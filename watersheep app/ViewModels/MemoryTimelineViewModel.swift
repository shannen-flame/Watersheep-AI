import Combine
import Foundation

@MainActor
final class MemoryTimelineViewModel: ObservableObject {
    enum DateFilter: String, CaseIterable, Identifiable {
        case all = "All Dates"
        case today = "Today"
        case thisWeek = "This Week"
        case earlier = "Earlier"

        var id: String { rawValue }
    }

    @Published var searchText = ""
    @Published var selectedObjectFilter: String = "All Objects"
    @Published var selectedPlaceFilter: String = "All Places"
    @Published var selectedDateFilter: DateFilter = .all
    @Published private(set) var items: [MemoryTimelineItem] = []

    init() {
        items = Self.mockItems
    }

    var filteredItems: [MemoryTimelineItem] {
        items.filter { item in
            matchesSearch(item)
                && matchesObject(item)
                && matchesPlace(item)
                && matchesDate(item)
        }
    }

    var objectFilters: [String] {
        ["All Objects"] + Set(items.flatMap(\.detectedObjects)).sorted()
    }

    var placeFilters: [String] {
        ["All Places"] + Set(items.map(\.location)).sorted()
    }

    func recordSystemEvent(_ detail: String) {
        appendIfNeeded(
            MemoryTimelineItem(
                title: "System",
                summary: detail,
                timestamp: .now,
                kind: .system,
                detectedObjects: [],
                location: "App Runtime",
                thumbnailSymbol: "gearshape.2"
            )
        )
    }

    func recordConnectionState(_ detail: String) {
        appendIfNeeded(
            MemoryTimelineItem(
                title: "Connection",
                summary: detail,
                timestamp: .now,
                kind: .connection,
                detectedObjects: ["glasses"],
                location: "Wearables",
                thumbnailSymbol: "dot.radiowaves.left.and.right"
            )
        )
    }

    func recordScene(_ scene: String) {
        guard isMeaningful(scene) else { return }
        appendIfNeeded(
            MemoryTimelineItem(
                title: "Scene Snapshot",
                summary: scene,
                timestamp: .now,
                kind: .scene,
                detectedObjects: extractedObjects(from: scene),
                location: "Live Capture",
                thumbnailSymbol: "camera.viewfinder"
            )
        )
    }

    func recordCommand(_ command: String) {
        guard isMeaningful(command) else { return }
        appendIfNeeded(
            MemoryTimelineItem(
                title: "Voice Command",
                summary: command,
                timestamp: .now,
                kind: .command,
                detectedObjects: [],
                location: "Voice Assistant",
                thumbnailSymbol: "waveform"
            )
        )
    }

    func recordAssistantReply(_ reply: String) {
        guard isMeaningful(reply) else { return }
        appendIfNeeded(
            MemoryTimelineItem(
                title: "Assistant Reply",
                summary: reply,
                timestamp: .now,
                kind: .assistant,
                detectedObjects: [],
                location: "Assistant",
                thumbnailSymbol: "sparkles"
            )
        )
    }

    private func appendIfNeeded(_ item: MemoryTimelineItem) {
        guard isMeaningful(item.summary) else { return }
        if items.first?.detail == item.detail, items.first?.kind == item.kind {
            return
        }

        items.insert(item, at: 0)
    }

    private func isMeaningful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = [
            "AI Vision is off.",
            "No assistant reply yet.",
            "No speech detected",
            "None",
        ]

        return !trimmed.isEmpty && !placeholders.contains(trimmed)
    }

    private func matchesSearch(_ item: MemoryTimelineItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let searchableText = [
            item.title,
            item.summary,
            item.location,
            item.detectedObjects.joined(separator: " "),
        ]
            .joined(separator: " ")
            .lowercased()

        return searchableText.contains(query.lowercased())
    }

    private func matchesObject(_ item: MemoryTimelineItem) -> Bool {
        selectedObjectFilter == "All Objects" || item.detectedObjects.contains(selectedObjectFilter)
    }

    private func matchesPlace(_ item: MemoryTimelineItem) -> Bool {
        selectedPlaceFilter == "All Places" || item.location == selectedPlaceFilter
    }

    private func matchesDate(_ item: MemoryTimelineItem) -> Bool {
        switch selectedDateFilter {
        case .all:
            return true
        case .today:
            return Calendar.current.isDateInToday(item.timestamp)
        case .thisWeek:
            return Calendar.current.isDate(item.timestamp, equalTo: .now, toGranularity: .weekOfYear)
        case .earlier:
            return !Calendar.current.isDateInToday(item.timestamp)
                && !Calendar.current.isDate(item.timestamp, equalTo: .now, toGranularity: .weekOfYear)
        }
    }

    private func extractedObjects(from scene: String) -> [String] {
        let keywords = ["laptop", "mug", "book", "phone", "bottle", "chair", "keyboard", "desk", "monitor", "bag"]
        return keywords.filter { scene.localizedCaseInsensitiveContains($0) }
    }

    private static let mockItems: [MemoryTimelineItem] = [
        MemoryTimelineItem(
            title: "Studio Desk Setup",
            summary: "Your desk setup includes a MacBook, mechanical keyboard, notebook, and coffee mug ready for a work session.",
            timestamp: .now.addingTimeInterval(-1_800),
            kind: .memory,
            detectedObjects: ["laptop", "keyboard", "notebook", "mug"],
            location: "Bedroom Studio",
            thumbnailSymbol: "laptopcomputer"
        ),
        MemoryTimelineItem(
            title: "Campus Walkway",
            summary: "You were walking past the engineering building with trees, bicycles, and several students nearby.",
            timestamp: .now.addingTimeInterval(-10_800),
            kind: .memory,
            detectedObjects: ["bicycle", "trees", "building"],
            location: "University Campus",
            thumbnailSymbol: "bicycle"
        ),
        MemoryTimelineItem(
            title: "Kitchen Counter Reminder",
            summary: "A water bottle, keys, and blue headphones were left on the kitchen counter.",
            timestamp: .now.addingTimeInterval(-86_400),
            kind: .memory,
            detectedObjects: ["bottle", "keys", "headphones"],
            location: "Kitchen",
            thumbnailSymbol: "waterbottle"
        ),
        MemoryTimelineItem(
            title: "Library Revision Session",
            summary: "You spent the afternoon revising with textbooks, a tablet, and highlighted notes spread across the table.",
            timestamp: .now.addingTimeInterval(-172_800),
            kind: .memory,
            detectedObjects: ["book", "tablet", "notes"],
            location: "University Library",
            thumbnailSymbol: "book.closed"
        ),
        MemoryTimelineItem(
            title: "Watersheep Ready",
            summary: "The app shell is ready for glasses, voice, and backend workflows.",
            timestamp: .now.addingTimeInterval(-259_200),
            kind: .system,
            detectedObjects: [],
            location: "App Runtime",
            thumbnailSymbol: "sparkles"
        ),
    ]
}
