import Foundation
import WebKit

/// Serves a verified `WebBundle` to a WKWebView under a custom URL scheme.
/// Only files the bundle's manifest lists are served; everything else is 404.
public final class WebBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "freenet-bundle"
    private let bundle: WebBundle

    public init(bundle: WebBundle) {
        self.bundle = bundle
    }

    /// The URL of the bundle's index page.
    public var indexURL: URL {
        URL(string: "\(Self.scheme)://\(bundle.name())/index.html")!
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path.isEmpty ? "/" : url.path
        if let file = bundle.resolve(urlPath: path) {
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": file.contentType,
                    "Content-Length": String(file.body.count),
                    "Cache-Control": "no-store",
                    "X-Content-SHA256": file.sha256,
                ]
            )!
            task.didReceive(response)
            task.didReceive(file.body)
            task.didFinish()
        } else {
            let response = HTTPURLResponse(
                url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            task.didReceive(response)
            task.didReceive(Data("not in the bundle manifest".utf8))
            task.didFinish()
        }
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Carries bridge messages between a page and `WebBridge`. The page sends
/// text through `window.webkit.messageHandlers.freenetHost`, and replies and
/// events come back through `window.__freenetHostReceive`.
public final class WebBridgeHost: NSObject, WKScriptMessageHandler {
    public static let handlerName = "freenetHost"
    public let bridge: WebBridge
    public weak var webView: WKWebView?

    public init(bridge: WebBridge) {
        self.bridge = bridge
    }

    /// Install the bridge script and message handler on a configuration.
    public func install(on configuration: WKWebViewConfiguration) {
        let script = WKUserScript(
            source: bridgeScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(self, name: Self.handlerName)
    }

    public func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let text = message.body as? String else { return }
        let bridge = self.bridge
        Task { @MainActor [weak self] in
            let reply = await bridge.handle(message: text)
            self?.deliver(reply)
        }
    }

    /// Send a reply or event to the page.
    @MainActor
    public func deliver(_ json: String) {
        guard let webView else { return }
        let literal = Self.jsStringLiteral(json)
        webView.evaluateJavaScript("window.__freenetHostReceive && window.__freenetHostReceive(\(literal))")
    }

    static func jsStringLiteral(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }
}
