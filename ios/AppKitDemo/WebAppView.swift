import SwiftUI
import UIKit
import WebKit

/// The hosted app, served by the embedded node. A main-frame script gives the
/// node's shell page a `Notification` that shows in-app alerts while the app
/// is open.
///
/// Every bridge message is checked before it acts: it must come from this web
/// view, from the frame and origin its handler serves, within the size limit,
/// during the session the page was loaded for, and with the permission it
/// needs. Prompts close when their session ends and their answers are dropped.
struct WebAppView: UIViewRepresentable {
    let app: HostedApp
    let url: URL
    /// Changes on every load the model asks for, so the same URL loads again
    /// in a new node session.
    let generation: Int
    /// The node session `url` belongs to.
    let session: UInt64?
    let model: WebAppModel
    @EnvironmentObject var host: NodeHost

    func makeCoordinator() -> Coordinator {
        Coordinator(app: app, host: host, model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(
            source: AlertShim.script(permission: host.alertGrant.rawValue),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: Coordinator.viewportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: Coordinator.frameReportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.add(context.coordinator, name: "appkitAlerts")
        controller.add(context.coordinator, name: "appkitFrames")
        let webView = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        // Swipe from the left edge goes back in the web app's history.
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(webView)
        context.coordinator.loaded = (url, generation)
        context.coordinator.session = session
        context.coordinator.load(url, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loaded.url != url || context.coordinator.loaded.generation != generation {
            context.coordinator.loaded = (url, generation)
            context.coordinator.session = session
            context.coordinator.startLoad()
            context.coordinator.load(url, in: webView)
        }
        context.coordinator.closeStalePrompt()
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.closePrompt()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let app: HostedApp
        let host: NodeHost
        weak var model: WebAppModel?
        weak var webView: WKWebView?
        var loaded: (url: URL?, generation: Int) = (nil, -1)
        /// The node session the loaded page belongs to.
        var session: UInt64?
        /// The permission prompt on screen, and the session that asked.
        private var prompt: (controller: UIAlertController, session: UInt64?)?

        /// Largest bridge message accepted, in bytes of its JSON form.
        static let maxMessageBytes = 8 * 1024
        static let maxTitleLength = 200
        static let maxBodyLength = 1_000
        private var appFrameSeen = false
        private var fallback: Task<Void, Never>?

        /// Longest the loading view stays once the app frame has loaded, for
        /// apps that draw nothing the paint check sees.
        static let paintFallbackSeconds: UInt64 = 15

        /// WebKit zooms in when a text field with a font under 16 px takes
        /// focus, and stays zoomed. A maximum scale of 1 on the shell page
        /// stops that zoom; pinch zoom still works.
        static let viewportScript = """
        (function () {
          var meta = document.querySelector('meta[name=viewport]');
          if (!meta) {
            meta = document.createElement('meta');
            meta.name = 'viewport';
            document.head.appendChild(meta);
          }
          meta.content = 'width=device-width, initial-scale=1, maximum-scale=1';
        })();
        """

        /// Every frame reports when its document is ready. The app frame also
        /// reports when it first shows text or media, which ends the loading
        /// view.
        static let frameReportScript = """
        (function () {
          function post(msg) {
            try { window.webkit.messageHandlers.appkitFrames.postMessage(msg); } catch (e) {}
          }
          var top = window === window.top;
          post({ kind: 'frame', top: top, href: String(location.href) });
          if (top) { return; }
          function painted() {
            var body = document.body;
            if (!body) { return false; }
            if (body.innerText && body.innerText.trim().length > 0) { return true; }
            var media = body.querySelectorAll('img, svg, canvas, video, input, button');
            for (var i = 0; i < media.length; i++) {
              var r = media[i].getBoundingClientRect();
              if (r.width > 0 && r.height > 0) { return true; }
            }
            return false;
          }
          var done = false, queued = false, observer;
          function check() {
            queued = false;
            if (done || !painted()) { return; }
            done = true;
            if (observer) { observer.disconnect(); }
            post({ kind: 'painted', top: false });
          }
          observer = new MutationObserver(function () {
            if (!queued) { queued = true; requestAnimationFrame(check); }
          });
          observer.observe(document, { childList: true, subtree: true, characterData: true });
          check();
        })();
        """

        init(app: HostedApp, host: NodeHost, model: WebAppModel) {
            self.app = app
            self.host = host
            self.model = model
        }

        func startLoad() {
            appFrameSeen = false
            fallback?.cancel()
            // A reconnect keeps the old page on screen until the new one draws.
            if model?.page != .reconnecting { model?.page = .fetching }
        }

        private func show() {
            fallback?.cancel()
            guard let model, model.page != .shown else { return }
            if case .failed = model.page { return }
            model.page = .shown
        }

        /// Give the web view this session's embedder secret as a cookie, then
        /// load. The node answers the shell page and the app's own requests
        /// only with it; HttpOnly keeps it from page scripts.
        func load(_ url: URL, in webView: WKWebView) {
            guard let secret = host.info?.embedderSecret, session == host.info?.session,
                  let cookie = HTTPCookie(properties: [
                      .name: "freenet-embedder", .value: secret, .domain: url.host ?? "127.0.0.1",
                      .path: "/", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
                      HTTPCookiePropertyKey("HttpOnly"): "TRUE",
                  ])
            else { return }
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak webView] in
                webView?.load(URLRequest(url: url))
            }
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        /// The shell page and its frames have loaded. With no app frame, the
        /// node answered with its own page, such as an error, so show it.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !appFrameSeen { show() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            failed(error)
        }

        private func failed(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            fallback?.cancel()
            model?.page = .failed(error.localizedDescription)
        }

        private func appFrameLoaded() {
            guard !appFrameSeen else { return }
            appFrameSeen = true
            if model?.page == .fetching { model?.page = .starting }
            fallback = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.paintFallbackSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.show()
            }
        }

        /// The current session's origin, the only one pages load from.
        private func isCurrentOrigin(_ url: URL?) -> Bool {
            guard let url, let origin = host.origin, session == host.info?.session else { return false }
            return url.scheme == "http" && url.host == origin.host && url.port == origin.port
        }

        /// Open a link outside the app: web links only, user-initiated, and
        /// only for the current session.
        private func openExternally(_ url: URL, action: WKNavigationAction) {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  action.navigationType == .linkActivated || action.navigationType == .other,
                  session == host.info?.session
            else { return }
            UIApplication.shared.open(url)
        }

        /// Main-frame navigations stay on the session's origin; web links go to
        /// the system browser and everything else is refused. Frames load as
        /// the page asks, inside WebKit's own rules.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if isCurrentOrigin(url) || url.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else {
                openExternally(url, action: navigationAction)
                decisionHandler(.cancel)
            }
        }

        /// Links that open a new window: the session's pages stay in this
        /// view, web links go to the system browser.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isCurrentOrigin(url) {
                    webView.load(URLRequest(url: url))
                } else {
                    openExternally(url, action: navigationAction)
                }
            }
            return nil
        }

        /// Whether `message` may act: this web view, the current session, the
        /// size limit and, for alerts, the main frame on the session's origin.
        private func admits(_ message: WKScriptMessage, body: [String: Any]) -> Bool {
            guard message.webView === webView, session != nil, session == host.info?.session else { return false }
            guard let bytes = try? JSONSerialization.data(withJSONObject: body),
                  bytes.count <= Self.maxMessageBytes
            else { return false }
            if message.name == "appkitAlerts" {
                let origin = message.frameInfo.securityOrigin
                guard message.frameInfo.isMainFrame, let current = host.origin,
                      origin.protocol == "http", origin.host == current.host, origin.port == current.port
                else { return false }
            }
            return true
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any], admits(message, body: body) else { return }
            switch message.name {
            case "appkitFrames":
                let top = body["top"] as? Bool ?? false
                if body["kind"] as? String == "painted" {
                    show()
                } else if !top {
                    appFrameLoaded()
                }
            case "appkitAlerts":
                handleAlert(body)
            default:
                break
            }
        }

        private func handleAlert(_ body: [String: Any]) {
            switch body["kind"] as? String {
            case "permission":
                askPermission()
            case "show":
                guard host.alertGrant == .granted else { return }
                let id = String((body["id"] as? String ?? "").filter(\.isNumber).prefix(16))
                let title = String((body["title"] as? String ?? app.name).prefix(Self.maxTitleLength))
                let text = String((body["body"] as? String ?? "").prefix(Self.maxBodyLength))
                let session = self.session
                let alert = InAppAlert(title: title, body: text) { [weak self] in
                    guard let self, self.session == session, session == self.host.info?.session else { return }
                    self.openAlert(id)
                }
                host.present(alert)
            default:
                break
            }
        }

        private func askPermission() {
            if host.alertGrant != .notAsked {
                answer(host.alertGrant.rawValue)
                return
            }
            guard prompt == nil else { return }
            let session = self.session
            let controller = UIAlertController(
                title: "Show message alerts from \(app.name)?",
                message: "Alerts appear only while \(AppInfo.shortName) is open.",
                preferredStyle: .alert)
            // The answer counts only if the session that asked is still current.
            let decide = { [weak self] (grant: AlertGrant) in
                guard let self else { return }
                self.prompt = nil
                guard self.session == session, session == self.host.info?.session else { return }
                self.host.alertGrant = grant
                self.answer(grant.rawValue)
            }
            controller.addAction(UIAlertAction(title: "Don't Allow", style: .cancel) { _ in decide(.denied) })
            controller.addAction(UIAlertAction(title: "Allow", style: .default) { _ in decide(.granted) })
            prompt = (controller, session)
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first?
                .present(controller, animated: true)
        }

        /// Close a prompt whose session has ended; its answer is dropped.
        func closeStalePrompt() {
            if let prompt, prompt.session != host.info?.session || prompt.session != session {
                closePrompt()
            }
        }

        func closePrompt() {
            prompt?.controller.dismiss(animated: false)
            prompt = nil
        }

        private func answer(_ permission: String) {
            webView?.evaluateJavaScript("window.__appkitAlertPermission && window.__appkitAlertPermission('\(permission)')")
        }

        /// The user tapped an alert: bring the app forward and let the web app
        /// route to the conversation, which reads verified state from the node.
        private func openAlert(_ id: String) {
            webView?.evaluateJavaScript("window.__appkitAlertClick && window.__appkitAlertClick('\(id)')")
        }
    }
}
