import FreenetAppKit
import SwiftUI
import WebKit

/// The host-served bundle route: a test page from the app's own verified
/// files, talking to the host over the JSON bridge and to the node over its
/// own WebSocket.
struct BridgeTestScreen: View {
    @EnvironmentObject var host: NodeHost
    @State private var ready = false
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                Text(error).foregroundStyle(.red).padding()
            } else if ready {
                BridgeWebView(generation: host.sessionGeneration)
            } else {
                ProgressView("Starting the node")
            }
        }
        .task(id: host.sessionGeneration) {
            ready = false
            if await host.start() != nil {
                ready = true
            } else {
                error = host.lastError ?? "The node did not start"
            }
        }
    }
}

/// Reports from the bridge test page, read by the harness.
@MainActor
final class BridgeReports: ObservableObject {
    static let shared = BridgeReports()
    @Published var latest: [String: Any]?
}

struct BridgeWebView: UIViewRepresentable {
    let generation: Int
    @EnvironmentObject var host: NodeHost

    func makeCoordinator() -> Coordinator { Coordinator(host: host) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.generation != generation {
            context.coordinator.generation = generation
            context.coordinator.reload(webView)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let host: NodeHost
        var generation = -1
        private var bridgeHost: WebBridgeHost?
        private var schemeHandler: WebBundleSchemeHandler?
        private var sinks: [UUID] = []

        init(host: NodeHost) { self.host = host }

        func makeWebView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            var bundle: WebBundle?
            do {
                bundle = try WebBundle.open(dir: AppResources.bridgeTestBundle.path)
            } catch {
                NSLog("AppKitDemo: bridge test bundle rejected: \(error)")
            }
            let bridge = WebBridge(node: host.node, bundle: bundle)
            let bridgeHost = WebBridgeHost(bridge: bridge)
            bridgeHost.install(on: config)
            config.userContentController.add(self, name: "appkitHarness")
            var indexURL = URL(string: "about:blank")!
            if let bundle {
                let handler = WebBundleSchemeHandler(bundle: bundle)
                config.setURLSchemeHandler(handler, forURLScheme: WebBundleSchemeHandler.scheme)
                schemeHandler = handler
                indexURL = handler.indexURL
            }
            let webView = WKWebView(frame: .zero, configuration: config)
            if #available(iOS 16.4, *) { webView.isInspectable = true }
            bridgeHost.webView = webView
            self.bridgeHost = bridgeHost
            sinks.append(host.addEventSink { [weak bridgeHost] event in
                guard let bridgeHost else { return }
                bridgeHost.deliver(bridgeHost.bridge.eventFor(event: event))
            })
            sinks.append(host.addLifecycleSink { [weak bridgeHost] phase in
                guard let bridgeHost else { return }
                bridgeHost.deliver(bridgeHost.bridge.lifecycleEvent(phase: phase))
            })
            let autorun = UserDefaults.standard.string(forKey: "appkit.scenario") == "bridge"
            let url = autorun ? URL(string: indexURL.absoluteString + "?autorun=1")! : indexURL
            webView.load(URLRequest(url: url))
            return webView
        }

        func reload(_ webView: WKWebView) {
            webView.reload()
        }

        func detach() {
            sinks.forEach(host.removeSink)
            sinks = []
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            if let report = message.body as? [String: Any] {
                BridgeReports.shared.latest = report
            }
        }
    }
}
