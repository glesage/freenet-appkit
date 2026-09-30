import SwiftUI
import UIKit
import WebKit

/// River or Atlas, served by the embedded node. A main-frame script gives the
/// node's shell page a `Notification` that shows in-app alerts while the app
/// is open.
struct WebAppView: UIViewRepresentable {
    let app: DemoWebApp
    let url: URL
    /// Changes on every load the model asks for, so the same URL loads again
    /// in a new node session.
    let generation: Int
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
        webView.load(URLRequest(url: url))
        context.coordinator.loaded = (url, generation)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loaded.url != url || context.coordinator.loaded.generation != generation {
            context.coordinator.loaded = (url, generation)
            context.coordinator.startLoad()
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let app: DemoWebApp
        let host: NodeHost
        weak var model: WebAppModel?
        weak var webView: WKWebView?
        var loaded: (url: URL?, generation: Int) = (nil, -1)
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

        init(app: DemoWebApp, host: NodeHost, model: WebAppModel) {
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

        /// Links that open a new window: loopback pages stay in this view,
        /// other sites go to the system browser.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                if url.host == "127.0.0.1" || url.host == "localhost" {
                    webView.load(URLRequest(url: url))
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
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
                let id = body["id"] as? String ?? ""
                let alert = InAppAlert(
                    title: body["title"] as? String ?? app.name,
                    body: body["body"] as? String ?? "",
                    tab: app.tab,
                    open: { [weak self] in self?.openAlert(id) })
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
            let prompt = UIAlertController(
                title: "Show message alerts from \(app.name)?",
                message: "Alerts appear only while AppKit Demo is open.",
                preferredStyle: .alert)
            prompt.addAction(UIAlertAction(title: "Don't Allow", style: .cancel) { [weak self] _ in
                self?.host.alertGrant = .denied
                self?.answer("denied")
            })
            prompt.addAction(UIAlertAction(title: "Allow", style: .default) { [weak self] _ in
                self?.host.alertGrant = .granted
                self?.answer("granted")
            })
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first?
                .present(prompt, animated: true)
        }

        private func answer(_ permission: String) {
            webView?.evaluateJavaScript("window.__appkitAlertPermission && window.__appkitAlertPermission('\(permission)')")
        }

        /// The user tapped an alert: bring the app forward and let the web app
        /// route to the conversation, which reads verified state from the node.
        private func openAlert(_ id: String) {
            let safe = id.filter(\.isNumber)
            webView?.evaluateJavaScript("window.__appkitAlertClick && window.__appkitAlertClick('\(safe)')")
        }
    }
}
