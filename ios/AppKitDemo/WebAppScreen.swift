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

@MainActor
final class WebAppModel: ObservableObject {
    @Published var url: URL?
    @Published var phase = "Starting the node"

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
        url = host.webURL(for: app)
        timeline.mark(app, "load_start")
    }
}

struct WebAppScreen: View {
    let app: DemoWebApp
    @EnvironmentObject var host: NodeHost
    @StateObject private var model = WebAppModel()

    var body: some View {
        Group {
            if let url = model.url {
                WebAppView(app: app, url: url, generation: host.sessionGeneration)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.phase)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        }
        .task(id: host.sessionGeneration) {
            await model.prepare(app: app, host: host)
        }
    }
}

/// River or Atlas, served by the embedded node. A main-frame script gives the
/// node's shell page a `Notification` that shows in-app alerts while the app
/// is open.
struct WebAppView: UIViewRepresentable {
    let app: DemoWebApp
    let url: URL
    let generation: Int
    @EnvironmentObject var host: NodeHost

    func makeCoordinator() -> Coordinator {
        Coordinator(app: app, host: host)
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
        weak var webView: WKWebView?
        var loaded: (url: URL?, generation: Int) = (nil, -1)
        private var titleObservation: NSKeyValueObservation?

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
        /// time the shell page and the app frame separately.
        static let frameReportScript = """
        (function () {
          try {
            window.webkit.messageHandlers.appkitFrames.postMessage({
              top: window === window.top, href: String(location.href), title: document.title
            });
          } catch (e) {}
        })();
        """

        init(app: DemoWebApp, host: NodeHost) {
            self.app = app
            self.host = host
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebTimeline.shared.mark(app, "shell_loaded")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            WebTimeline.shared.mark(app, "load_failed:\(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            WebTimeline.shared.mark(app, "load_failed:\(error.localizedDescription)")
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
                WebTimeline.shared.mark(app, top ? "shell_dom" : "app_frame_dom")
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
