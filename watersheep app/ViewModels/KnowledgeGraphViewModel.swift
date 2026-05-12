import Foundation

@MainActor
final class KnowledgeGraphViewModel: ObservableObject {
    @Published var htmlContent: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let client: BackendClient? = try? BackendClient()

    func loadGraph() async {
        guard let client else {
            errorMessage = "Backend not configured."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            htmlContent = try await client.fetchGraphHTML()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
