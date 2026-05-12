import SwiftUI
import WebKit

struct KnowledgeGraphView: View {
    @StateObject private var viewModel = KnowledgeGraphViewModel()

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .navigationTitle("Knowledge Graph")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.loadGraph() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.white)
                }
                .disabled(viewModel.isLoading)
            }
        }
        .task { await viewModel.loadGraph() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                Text("Building graph…")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(error)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") {
                    Task { await viewModel.loadGraph() }
                }
                .foregroundStyle(.cyan)
            }
        } else if viewModel.htmlContent.isEmpty {
            Text("No memories yet — start capturing!")
                .foregroundStyle(Color.white.opacity(0.6))
        } else {
            GraphWebView(htmlContent: viewModel.htmlContent)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct GraphWebView: UIViewRepresentable {
    let htmlContent: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }
}
