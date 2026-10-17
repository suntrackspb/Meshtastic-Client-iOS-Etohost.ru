import SwiftUI
import WebKit

/// Карта ретрансляций сообщения из зеркала (`/relay/:id`, RelayMapStandaloneView.vue).
struct RelayMapSheet: View {
    let mirrorId: Int
    @Environment(\.dismiss) private var dismiss

    private var url: URL { MirrorAPI.baseURL.appending(path: "relay/\(mirrorId)") }

    var body: some View {
        NavigationStack {
            WebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Ретрансляции")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Link(destination: url) { Image(systemName: "safari") }
                            .accessibilityLabel("Открыть в Safari")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { dismiss() }
                    }
                }
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Нужен для `.sheet(item:)`.
struct RelayMapTarget: Identifiable {
    let id: Int
}
