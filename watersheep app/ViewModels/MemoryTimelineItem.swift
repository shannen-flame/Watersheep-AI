import Foundation

struct MemoryTimelineItem: Identifiable, Equatable {
    enum Kind: String {
        case memory
        case system
        case connection
        case scene
        case command
        case assistant
    }

    let id = UUID()
    let title: String
    let summary: String
    let timestamp: Date
    let kind: Kind
    let detectedObjects: [String]
    let location: String
    let thumbnailSymbol: String?

    var detail: String {
        summary
    }

    init(
        title: String,
        summary: String,
        timestamp: Date,
        kind: Kind,
        detectedObjects: [String] = [],
        location: String = "Unknown location",
        thumbnailSymbol: String? = nil
    ) {
        self.title = title
        self.summary = summary
        self.timestamp = timestamp
        self.kind = kind
        self.detectedObjects = detectedObjects
        self.location = location
        self.thumbnailSymbol = thumbnailSymbol
    }
}
