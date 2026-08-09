import SwiftUI
import WebKit

/// The "press the download button" solver. File hosts that gate their files behind a button, a
/// captcha or a wait timer defeat any headless fetcher — so let the HUMAN do the human part: this
/// sheet opens the page in a real browser, the owner taps the host's own download button, and the
/// moment the host actually serves the FILE we intercept it, capture the resolved URL plus the
/// cookies/Referer/User-Agent that made it valid, cancel the local download, and hand the whole
/// bundle to the server to do the transfer.
///
/// Caveat by design: hosts that sign file URLs to the requesting IP work when phone and server share
/// an egress IP (home wifi) and can fail away from home — the server-side fetch then errors visibly
/// on its card rather than silently.
struct LinkResolverSheet: View {
    let startURL: URL
    /// (resolved file URL, suggested filename, headers to replay). Called once; the sheet dismisses.
    let onResolved: (URL, String, [String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pageTitle = ""
    @State private var captured = false

    var body: some View {
        NavigationStack {
            ResolverWebView(startURL: startURL, pageTitle: $pageTitle) { url, filename, headers in
                guard !captured else { return }   // one capture per session — hosts love double-fires
                captured = true
                Haptics.notify(.success)
                onResolved(url, filename, headers)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(pageTitle.isEmpty ? "Resolve Link" : pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("Tap the site's download button — Stashy grabs the file link and sends it to your server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.thinMaterial)
            }
        }
    }
}

private struct ResolverWebView: UIViewRepresentable {
    let startURL: URL
    @Binding var pageTitle: String
    let onResolved: (URL, String, [String: String]) -> Void

    /// One Safari-like UA used for BOTH the browsing session and the replayed server fetch, so the
    /// host can't tell the downloader from the browser that clicked.
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent: the session's cookies exist to be CAPTURED, not to accumulate a browsing
        // profile inside the app. Each resolve starts clean.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = Self.userAgent
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        web.load(URLRequest(url: startURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        var parent: ResolverWebView
        weak var webView: WKWebView?
        init(parent: ResolverWebView) { self.parent = parent }

        // MARK: Route file responses into a WKDownload

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // A response the web view can't display inline IS the file being served (video/*,
            // octet-stream, attachment disposition all land here).
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Anchor tags with a `download` attribute skip the response phase entirely.
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.pageTitle = webView.title ?? ""
        }

        // MARK: The capture point

        func download(_ download: WKDownload,
                      decideDestinationUsing response: URLResponse,
                      suggestedFilename: String,
                      completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
            // `response.url` is the REAL file URL — after every redirect, token and signature the
            // host applied. That, plus this session's cookies, is exactly what the server needs.
            guard let fileURL = response.url else {
                completionHandler(nil)
                return
            }
            let referer = webView?.url?.absoluteString
            let store = webView?.configuration.websiteDataStore.httpCookieStore
            Task { @MainActor [parent] in
                var headers: [String: String] = ["User-Agent": ResolverWebView.userAgent]
                if let referer { headers["Referer"] = referer }
                if let store {
                    let cookies = await store.allCookies()
                    let host = fileURL.host() ?? ""
                    // Send the cookies a browser would: this host and its parent domains.
                    let matching = cookies.filter { cookie in
                        let d = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                        return host == d || host.hasSuffix("." + d)
                    }
                    if !matching.isEmpty {
                        headers["Cookie"] = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    }
                }
                parent.onResolved(fileURL, suggestedFilename, headers)
                completionHandler(nil)   // nil destination = cancel the LOCAL download — the server does it
            }
        }

        func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
            // Expected: cancelling via a nil destination reports as a failure. Nothing to do.
        }
    }
}
