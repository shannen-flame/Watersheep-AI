import SwiftUI
import WebKit

struct KnowledgeGraphView: View {
    @State private var htmlContent: String?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            AppBackground()

            Group {
                if let htmlContent {
                    KnowledgeGraphWebView(htmlContent: htmlContent)
                } else if let errorMessage {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Unable to load graph", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.white)

                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.74))

                            Button("Retry") {
                                Task {
                                    await loadGraph()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(20)
                } else {
                    ProgressView("Loading graph...")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
        }
        .navigationTitle("Knowledge Graph")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard htmlContent == nil, !isLoading else { return }
            await loadGraph()
        }
    }

    @MainActor
    private func loadGraph() async {
        isLoading = true
        errorMessage = nil

        do {
            let client = try BackendClient()
            let html = try await client.fetchGraphHTML()
            htmlContent = html.isEmpty ? fallbackHTML : html
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private var fallbackHTML: String {
        """
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    background: #0f172a;
                    color: white;
                    padding: 24px;
                }
            </style>
        </head>
        <body>
            <h2>Knowledge graph unavailable</h2>
            <p>The backend returned an empty HTML payload.</p>
        </body>
        </html>
        """
    }
}

private struct KnowledgeGraphWebView: UIViewRepresentable {
    let htmlContent: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }
}
