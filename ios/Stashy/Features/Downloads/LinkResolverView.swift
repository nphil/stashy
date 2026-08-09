import SwiftUI
import WebKit

/// The "press the download button" solver. File hosts that gate their files behind a button, a
/// captcha or a wait timer defeat any headless fetcher — so let the HUMAN do the human part: this
/// sheet opens the page in a real browser, the owner taps the host's own download button, and the
/// moment the host actually serves the FILE we intercept it, capture the resolved URL plus the
/// cookies/Referer/User-Agent that made it valid, cancel the local download, and hand the whole
/// bundle to the server to do the transfer.
///
/// Ad armor (owner 2026-08-09: "when I click the download button, the window goes to the ad site
/// and there's no way to go back"):
///  * Popups/new tabs NEVER replace the visible page. Each gets an OFFSCREEN web view wired to the
///    same delegates — a popup that turns out to be the file is captured exactly like the main
///    view (hosts love serving the download via the popup), while an ad page renders to nowhere.
///  * The visible page can still be same-tab-redirected by a click; the ‹ › toolbar arrows are the
///    way back. Non-web schemes (App Store, market://, custom apps) are refused outright.
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
    @State private var page = ResolverPageState()

    var body: some View {
        NavigationStack {
            ResolverWebView(startURL: startURL, pageTitle: $pageTitle, page: page) { url, filename, headers in
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
                // The escape hatch from same-tab ad redirects: real browser back/forward.
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { page.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!page.canGoBack)
                    Button { page.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!page.canGoForward)
                    Spacer()
                    Button { page.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("Tap the site's download button — popup ads are contained automatically; use ‹ if the page jumps away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.thinMaterial)
            }
        }
    }
}

/// Toolbar ↔ web view bridge: mirrors the main web view's back/forward state for SwiftUI (synced
/// from the navigation-delegate callbacks — no KVO on the MainActor-isolated WKWebView) and relays
/// the button verbs.
@MainActor @Observable
final class ResolverPageState {
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored weak var webView: WKWebView?
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

private struct ResolverWebView: UIViewRepresentable {
    let startURL: URL
    @Binding var pageTitle: String
    let page: ResolverPageState
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
        web.uiDelegate = context.coordinator
        context.coordinator.webView = web
        page.webView = web
        web.load(URLRequest(url: startURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: ResolverWebView
        weak var webView: WKWebView?
        /// Offscreen popup web views (ads and file-serving popups alike). Capped — evicted ones
        /// stop loading, so a popup storm can't pile up work behind the visible page.
        private var popups: [WKWebView] = []
        init(parent: ResolverWebView) { self.parent = parent }

        // MARK: Route file responses into a WKDownload

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            // A response the web view can't display inline IS the file being served (video/*,
            // octet-stream, attachment disposition all land here). Fires for popups too — they
            // share this delegate — which is how a popup-served download still gets captured.
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Ad scripts adore non-web schemes (itms-apps, market://, custom app hops). Refuse
            // them — only web navigations (+ the blank/blob/data states popups bootstrap through)
            // belong in this sheet.
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               !["http", "https", "about", "blob", "data"].contains(scheme) {
                decisionHandler(.cancel)
                return
            }
            // Anchor tags with a `download` attribute skip the response phase entirely.
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }

        // Popups/new tabs (`target="_blank"`, window.open — on file hosts: usually the ad, sometimes
        // the actual download). Never let one replace the visible page: host it OFFSCREEN with the
        // same delegates. A file-serving popup hits the response policy above and is captured; an ad
        // renders to nowhere. WebKit requires the returned view use the provided configuration —
        // which also shares the session's cookie store, so popup cookies are captured too.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = ResolverWebView.userAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popups.append(popup)
            if popups.count > 4 {
                popups.removeFirst().stopLoading()
            }
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            webView.stopLoading()
            popups.removeAll { $0 === webView }
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        // MARK: Main-page state for the toolbar (popups are guarded out — they're invisible)

        private func syncPageState(_ web: WKWebView) {
            guard web === webView else { return }
            parent.page.canGoBack = web.canGoBack
            parent.page.canGoForward = web.canGoForward
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            syncPageState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if webView === self.webView {
                parent.pageTitle = webView.title ?? ""
            }
            syncPageState(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            syncPageState(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            syncPageState(webView)
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
