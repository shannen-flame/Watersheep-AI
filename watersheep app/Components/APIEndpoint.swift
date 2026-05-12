import Foundation

enum APIEndpoint {
    case health
    case apiHealth
    case chat(ChatBackendRequest)

    var path: String {
        switch self {
        case .health:
            return "health"
        case .apiHealth:
            return "api/health"
        case .chat:
            return "chat"
        }
    }

    var method: String {
        switch self {
        case .health, .apiHealth:
            return "GET"
        case .chat:
            return "POST"
        }
    }

    var body: Data? {
        let encoder = JSONEncoder()

        switch self {
        case .health, .apiHealth:
            return nil
        case .chat(let request):
            return try? encoder.encode(request)
        }
    }
}
