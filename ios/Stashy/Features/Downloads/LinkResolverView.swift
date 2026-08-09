import SwiftUI
import WebKit

/// The "press the download button" solver. File hosts that gate their files behind a button, a
/// captcha or a wait timer defeat any headless fetcher — so let the HUMAN do the human part: this
/// sheet opens the page in a real browser, the owner taps the host's own download button, and the
/// moment the host actually serves the FILE we intercept it, capture the resolved URL plus the
/// cookies/Referer/User-Agent that made it valid, cancel the local download, and hand the whole
/// bundle to the server to do the transfer.
///
/// Capture surfaces, broadest first (owner 2026-08-09: "instead of downloading, the video starts
/// playing on the browser window" + "capture streaming only links"):
///  * Main-frame MEDIA responses (video/*, HLS manifests…) are captured, never played — WKWebView
///    would happily show them inline (`canShowMIMEType` is true for video), which is exactly the
///    reported bug.
///  * Responses the web view can't display (octet-stream, attachment) become WKDownloads — the
///    original path.
///  * A JS sniffer watches every frame's fetch/XHR/<video> for stream URLs (.m3u8/.mpd/.mp4…), so
///    embedded players that stream via MSE/blob still yield their real manifest.
///  * The **Send** toolbar button ships the sniffed stream — or, with nothing sniffed, the page URL
///    itself for server-side yt-dlp extraction (hundreds of site extractors + generic).
///
/// Ad armor (owner 2026-08-09): popups NEVER replace the visible page — each gets an OFFSCREEN web
/// view wired to the same delegates (a file-serving popup is captured; an ad renders to nowhere),
/// and the ‹ › toolbar arrows escape same-tab redirects. Non-web schemes are refused.
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
                    Button("Done") { dismiss() }
                }
                // The whole browser chrome lives in one thin bottom bar (owner: "treat it as a real
                // browser, immersive fullscreen" — the instruction banner that used to sit up top is
                // gone). ‹ › escape same-tab ad redirects; the labelled button is the manual capture
                // (sniffed stream if the player gave one up, else the page URL for server yt-dlp).
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { page.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!page.canGoBack)
                    Button { page.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!page.canGoForward)
                    Spacer()
                    Button(page.sniffedCount > 0 ? "Send Stream" : "Send Page") { page.sendCurrent?() }
                        .fontWeight(.semibold)
                    Spacer()
                    Button { page.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

/// Toolbar ↔ web view bridge: mirrors the main web view's back/forward state for SwiftUI (synced
/// from the navigation-delegate callbacks — no KVO on the MainActor-isolated WKWebView), relays the
/// button verbs, and accumulates sniffed stream URLs.
@MainActor @Observable
final class ResolverPageState {
    var canGoBack = false
    var canGoForward = false
    /// Drives the Send button's label; bumped as the sniffer reports.
    private(set) var sniffedCount = 0
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var sendCurrent: (@MainActor () -> Void)?
    @ObservationIgnored private var sniffed: [URL] = []

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func noteSniffed(_ url: URL) {
        guard !sniffed.contains(url) else { return }
        sniffed.append(url)
        sniffedCount = sniffed.count
    }

    /// A new main-page navigation invalidates what the old page's player was fetching.
    func clearSniffed() {
        sniffed.removeAll()
        sniffedCount = 0
    }

    /// The URL the Send button ships: prefer the newest MANIFEST (the active stream a player is
    /// actually using), then the newest direct file, else nil (caller falls back to the page URL).
    var bestSniffed: URL? {
        let manifests = sniffed.filter { ["m3u8", "mpd"].contains($0.pathExtension.lowercased()) }
        return manifests.last ?? sniffed.last
    }
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

    /// Injected into every frame at document start (page world, so the PAGE's fetch/XHR get hooked):
    /// reports any URL that looks like a stream manifest or a video file. This is how "streaming
    /// only" sites give up their real .m3u8 — the player has to fetch it, and we're watching.
    static let snifferJS = """
    (function () {
      if (window.__stashySniff) { return; } window.__stashySniff = true;
      var seen = {};
      function report(u) {
        try {
          if (!u || typeof u !== 'string' || u.indexOf('blob:') === 0) { return; }
          var abs = new URL(u, location.href).href;
          if (!/\\.(m3u8|mpd|mp4|m4v|webm|mov)([?#]|$)/i.test(abs)) { return; }
          if (seen[abs]) { return; } seen[abs] = 1;
          window.webkit.messageHandlers.stashyMedia.postMessage(abs);
        } catch (e) {}
      }
      var of = window.fetch;
      if (of) {
        window.fetch = function (input) {
          try { report(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
          return of.apply(this, arguments);
        };
      }
      var oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) {
        try { report(u); } catch (e) {}
        return oo.apply(this, arguments);
      };
      setInterval(function () {
        try {
          var els = document.querySelectorAll('video, source');
          for (var i = 0; i < els.length; i++) {
            report(els[i].currentSrc || els[i].src);
          }
        } catch (e) {}
      }, 2000);
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent: the session's cookies exist to be CAPTURED, not to accumulate a browsing
        // profile inside the app. Each resolve starts clean.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.snifferJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // Weak relay, not the coordinator itself: WKUserContentController retains its handler
        // STRONGLY, and a popup's controller can reach back through the coordinator to the popup —
        // the weak hop makes the cycle impossible by construction.
        let relay = ScriptRelay()
        relay.target = context.coordinator
        config.userContentController.add(relay, name: "stashyMedia")
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = Self.userAgent
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.webView = web
        page.webView = web
        let coordinator = context.coordinator
        page.sendCurrent = { [weak coordinator] in coordinator?.sendCurrentToServer() }
        web.load(URLRequest(url: startURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// The sniffer's message hop. Weak target only — see the comment at the `add(_:name:)` site.
    @MainActor
    private final class ScriptRelay: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            target?.handleSniffedMedia(message)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: ResolverWebView
        weak var webView: WKWebView?
        /// Offscreen popup web views (ads and file-serving popups alike). Capped — evicted ones
        /// stop loading, so a popup storm can't pile up work behind the visible page.
        private var popups: [WKWebView] = []
        init(parent: ResolverWebView) { self.parent = parent }

        // MARK: Route file AND media responses into the capture

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            // A main-frame navigation to MEDIA is the file being served — but `canShowMIMEType` is
            // TRUE for video (WKWebView would play it inline), so it needs its own check before the
            // generic gate. `.download` routes it into the capture; main-frame only, or ad iframes
            // with autoplaying teasers would fire it.
            if navigationResponse.isForMainFrame,
               Self.isMediaMIME(navigationResponse.response.mimeType) {
                decisionHandler(.download)
                return
            }
            // A response the web view can't display inline IS the file being served (octet-stream,
            // attachment disposition land here). Fires for popups too — they share this delegate —
            // which is how a popup-served download still gets captured.
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        private static func isMediaMIME(_ mime: String?) -> Bool {
            guard let mime = mime?.lowercased() else { return false }
            return mime.hasPrefix("video/")
                || ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl",
                    "application/dash+xml"].contains(mime)
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
            if webView === self.webView {
                parent.page.clearSniffed()   // the old page's player streams are history now
            }
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

        // MARK: Sniffed streams + the Send button

        func handleSniffedMedia(_ message: WKScriptMessage) {
            guard let raw = message.body as? String,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { return }
            parent.page.noteSniffed(url)
        }

        /// Manual capture: the sniffed stream if there is one, else the page URL itself — the
        /// server's yt-dlp resolves pages with its site extractors + generic extraction.
        func sendCurrentToServer() {
            guard let target = parent.page.bestSniffed ?? webView?.url,
                  let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { return }
            // A direct file keeps its own name; manifests and pages get "" so yt-dlp's title
            // template names the output (naming an HLS download "master.m3u8" would be wrong).
            let ext = target.pathExtension.lowercased()
            let filename = ["mp4", "m4v", "webm", "mov"].contains(ext) ? target.lastPathComponent : ""
            Task { @MainActor in
                let headers = await self.replayHeaders(for: target)
                self.parent.onResolved(target, filename, headers)
            }
        }

        // MARK: The download capture point

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
            Task { @MainActor in
                let headers = await self.replayHeaders(for: fileURL)
                self.parent.onResolved(fileURL, suggestedFilename, headers)
                completionHandler(nil)   // nil destination = cancel the LOCAL download — the server does it
            }
        }

        func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
            // Expected: cancelling via a nil destination reports as a failure. Nothing to do.
        }

        /// The headers that make the captured URL valid for the server: this session's cookies for
        /// the target's domain (and parents), the current page as Referer + Origin, the shared UA.
        private func replayHeaders(for target: URL) async -> [String: String] {
            var headers: [String: String] = ["User-Agent": ResolverWebView.userAgent]
            if let pageURL = webView?.url {
                headers["Referer"] = pageURL.absoluteString
                // The page's player fetches streams via CORS, and token-gated stream backends
                // VALIDATE the Origin it sends — a replay without one 403s (owner hit this on a
                // tokenized master.m3u8 whose token was seconds old).
                if let scheme = pageURL.scheme, let host = pageURL.host() {
                    headers["Origin"] = pageURL.port.map { "\(scheme)://\(host):\($0)" }
                        ?? "\(scheme)://\(host)"
                }
            }
            if let store = webView?.configuration.websiteDataStore.httpCookieStore {
                let cookies = await store.allCookies()
                let host = target.host() ?? ""
                let matching = cookies.filter { cookie in
                    let d = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                    return host == d || host.hasSuffix("." + d)
                }
                if !matching.isEmpty {
                    // Flattened header: what the plain-HTTP fallback (and plugin ≤0.5.1) replays.
                    headers["Cookie"] = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    // Structured copy WITH each cookie's own domain/path: plugin ≥0.5.2 builds a
                    // real Netscape jar from it (yt-dlp --cookies), so cookies scope correctly
                    // across a stream host's subdomain hops instead of riding one raw header.
                    let jar: [[String: String]] = matching.map {
                        ["name": $0.name, "value": $0.value, "domain": $0.domain,
                         "path": $0.path.isEmpty ? "/" : $0.path]
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: jar),
                       let json = String(data: data, encoding: .utf8) {
                        headers["X-Stashy-Cookie-Jar"] = json
                    }
                }
            }
            return headers
        }
    }
}
