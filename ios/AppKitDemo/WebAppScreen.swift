import FreenetAppKit
import SwiftUI
import WebKit

/// The live web view of each web app, for the harness.
@MainActor
enum WebViews {
    static var byApp: [String: WKWebView] = [:]
}

/// Load timeline of each web app, read by the harness.
@MainActor
final class WebTimeline: ObservableObject {
    static let shared = WebTimeline()
    struct Mark: Codable { let event: String; let ms: Double }
    @Published private(set) var marks: [String: [Mark]] = [:]

    func reset(_ app: DemoWebApp) { marks[app.name] = [] }

    func mark(_ app: DemoWebApp, _ event: String) {
        marks[app.name, default: []].append(Mark(event: event, ms: ProcessClock.nowMs()))
    }

    func first(_ app: DemoWebApp, prefix: String) -> Mark? {
        marks[app.name]?.first { $0.event.hasPrefix(prefix) }
    }
}

/// How far the web app has got once the node serves its page.
enum PageState: Equatable {
    /// The node is fetching the website container.
    case fetching
    /// The app's frame is loading its code.
    case starting
    /// The app has drawn something, or the node showed its own page.
    case shown
    case failed(String)
}

@MainActor
final class WebAppModel: ObservableObject {
    @Published var url: URL?
    @Published var phase = "Starting the node"
    @Published var page: PageState = .fetching

    func prepare(app: DemoWebApp, host: NodeHost) async {
        let timeline = WebTimeline.shared
        url = nil
        timeline.reset(app)
        timeline.mark(app, "prepare")
        phase = "Starting the node"
        guard await host.start() != nil else {
            phase = "The node did not start.\n\(host.lastError ?? "")"
            return
        }
        timeline.mark(app, "node_running")
        if host.profile != .local {
            phase = "Waiting for a peer"
            guard await host.waitForPeers() else {
                phase = "No peer answered.\n\(host.lastError ?? "")"
                return
            }
            timeline.mark(app, "first_peer")
        } else {
            phase = "Loading \(app.name) into the local node"
            do {
                try await host.preloadIfLocal(app)
                timeline.mark(app, "preloaded")
            } catch {
                phase = "\(app.name) is not available offline.\n\(error.localizedDescription)"
                return
            }
        }
        page = .fetching
        url = host.webURL(for: app)
        timeline.mark(app, "load_start")
    }

    func pageText(app: DemoWebApp, host: NodeHost) -> String {
        switch page {
        case .fetching:
            return host.profile == .local ? "Opening \(app.name)" : "Fetching \(app.name) from the network"
        case .starting:
            return "Starting \(app.name)"
        case .shown:
            return ""
        case .failed(let message):
            return "\(app.name) did not load.\n\(message)"
        }
    }
}

struct WebAppScreen: View {
    let app: DemoWebApp
    @EnvironmentObject var host: NodeHost
    @StateObject private var model = WebAppModel()

    var body: some View {
        ZStack {
            if let url = model.url {
                WebAppView(app: app, url: url, generation: host.sessionGeneration, model: model)
                    .ignoresSafeArea(edges: .bottom)
                if model.page != .shown {
                    LoadingView(
                        text: model.pageText(app: app, host: host),
                        failed: model.page != .fetching && model.page != .starting,
                        retry: { Task { await model.prepare(app: app, host: host) } })
                }
            } else {
                LoadingView(text: model.phase, failed: false, retry: nil)
            }
        }
        .task(id: host.sessionGeneration) {
            await model.prepare(app: app, host: host)
        }
    }
}

/// A spinner and a line of text over the whole screen, or the error and a
/// retry button once loading failed.
struct LoadingView: View {
    let text: String
    let failed: Bool
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if !failed { ProgressView() }
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if failed, let retry {
                Button("Try again", action: retry).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

/// River or Atlas, served by the embedded node. A main-frame script gives the
/// node's shell page a `Notification` that shows in-app alerts while the app
/// is open.
struct WebAppView: UIViewRepresentable {
    let app: DemoWebApp
    let url: URL
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
        if #available(iOS 16.4, *) { webView.isInspectable = true }
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
        private var titleObservation: NSKeyValueObservation?
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

        /// Every frame reports when its document is ready, so the harness can
        /// time the shell page and the app frame separately. The app frame
        /// also reports when it first shows text or media, which ends the
        /// loading view.
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
            model?.page = .fetching
        }

        private func show() {
            fallback?.cancel()
            guard let model, model.page != .shown else { return }
            if case .failed = model.page { return }
            model.page = .shown
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            WebViews.byApp[app.name] = webView
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                let title = view.title ?? ""
                Task { @MainActor in
                    guard let self, !title.isEmpty else { return }
                    WebTimeline.shared.mark(self.app, "title:\(title)")
                }
            }
        }

        /// The shell page and its frames have loaded. With no app frame, the
        /// node answered with its own page, such as an error, so show it.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebTimeline.shared.mark(app, "shell_loaded")
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
            WebTimeline.shared.mark(app, "load_failed:\(error.localizedDescription)")
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
                    WebTimeline.shared.mark(app, "app_painted")
                    show()
                } else {
                    WebTimeline.shared.mark(app, top ? "shell_dom" : "app_frame_dom")
                    if !top { appFrameLoaded() }
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
                WebTimeline.shared.mark(app, "alert_shown")
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
            WebTimeline.shared.mark(app, "alert_opened")
            let safe = id.filter(\.isNumber)
            webView?.evaluateJavaScript("window.__appkitAlertClick && window.__appkitAlertClick('\(safe)')")
        }
    }
}

/// A `Notification` for the node's shell page that hands alerts to the host.
enum AlertShim {
    static func script(permission: String) -> String {
        """
        (function () {
          var granted = '\(permission)';
          var live = {};
          var next = 0;
          var waiting = [];
          function post(msg) {
            try { window.webkit.messageHandlers.appkitAlerts.postMessage(msg); } catch (e) {}
          }
          function HostNotification(title, options) {
            options = options || {};
            this.title = String(title);
            this.body = typeof options.body === 'string' ? options.body : '';
            this.tag = typeof options.tag === 'string' ? options.tag : '';
            this.data = options.data;
            this.onclick = null;
            this._id = String(++next);
            live[this._id] = this;
            post({ kind: 'show', id: this._id, title: this.title, body: this.body, tag: this.tag });
          }
          HostNotification.prototype.close = function () { delete live[this._id]; };
          HostNotification.prototype.addEventListener = function (type, cb) {
            if (type === 'click') { this.onclick = cb; }
          };
          Object.defineProperty(HostNotification, 'permission', { get: function () { return granted; } });
          HostNotification.requestPermission = function (callback) {
            return new Promise(function (resolve) {
              waiting.push(function (answer) {
                granted = answer;
                if (typeof callback === 'function') { callback(answer); }
                resolve(answer);
              });
              post({ kind: 'permission' });
            });
          };
          window.__appkitAlertPermission = function (answer) {
            granted = answer;
            var pending = waiting;
            waiting = [];
            pending.forEach(function (f) { f(answer); });
          };
          window.__appkitAlertClick = function (id) {
            var n = live[id];
            if (n && typeof n.onclick === 'function') { n.onclick({ target: n }); }
          };
          window.Notification = HostNotification;
        })();
        """
    }
}
