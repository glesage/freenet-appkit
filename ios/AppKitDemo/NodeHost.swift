import FreenetAppKit
import SwiftUI
import UIKit

/// A foreground message alert from a web app.
struct InAppAlert: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let tab: DemoTab
    let open: () -> Void
}

/// The user's answer to "show message alerts", kept per app.
enum AlertGrant: String {
    case notAsked = "default", granted, denied
}

/// Owns the embedded node for the whole app and runs it only while the app is
/// in the foreground.
@MainActor
final class NodeHost: ObservableObject {
    static let shared = NodeHost()

    @Published var selectedTab: DemoTab = .river
    @Published private(set) var status: NodeStatus?
    @Published private(set) var info: NodeInfo?
    @Published private(set) var lastError: String?
    /// Increases on every fresh session, so web views reload with new authority.
    @Published private(set) var sessionGeneration = 0
    @Published var alert: InAppAlert?
    @Published var alertGrant: AlertGrant {
        didSet { defaults.set(alertGrant.rawValue, forKey: Keys.alerts) }
    }
    /// The user has tapped "Continue" on the welcome screen. The node starts
    /// only after that, so the local network prompt comes after the welcome.
    @Published var welcomeSeen: Bool {
        didSet { defaults.set(welcomeSeen, forKey: Keys.welcomeSeen) }
    }

    private(set) var node: MobileNode?
    /// `nil` when the node's folders could not be created; `start()` then
    /// reports the error instead of starting.
    let directories: NodeDirectories?
    private var listener: HostListener?
    private let defaults = UserDefaults.standard

    enum Keys {
        static let alerts = "appkit.alerts"
        static let port = "appkit.lastPort"
        static let welcomeSeen = "appkit.welcomeSeen"
    }

    private init() {
        directories = try? NodeDirectories.standard()
        alertGrant = AlertGrant(rawValue: defaults.string(forKey: Keys.alerts) ?? "") ?? .notAsked
        welcomeSeen = defaults.bool(forKey: Keys.welcomeSeen)
    }

    // MARK: Settings

    /// The node always joins the public network. It asks for the last
    /// WebSocket port again, so web app data stored per origin stays reachable.
    private func settings(in directories: NodeDirectories) -> NodeSettings {
        let lastPort = UInt16(clamping: defaults.integer(forKey: Keys.port))
        return directories.settings(mode: .network, preferredWsPort: lastPort == 0 ? nil : lastPort)
    }

    // MARK: Lifecycle

    /// Start the node. Repeated calls return the running node.
    @discardableResult
    func start() async -> NodeInfo? {
        guard let directories else {
            lastError = "Freenet could not create its folders on this device."
            return nil
        }
        do {
            let node = try currentNode(directories: directories)
            let info = try await node.start()
            self.info = info
            self.status = node.status()
            self.lastError = nil
            defaults.set(Int(info.wsPort), forKey: Keys.port)
            return info
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    func stop() async {
        guard let node else { return }
        do {
            try await node.stop()
        } catch {
            lastError = "\(error)"
        }
        info = nil
        status = node.status()
    }

    private func currentNode(directories: NodeDirectories) throws -> MobileNode {
        if let node { return node }
        let node = try MobileNode(settings: settings(in: directories))
        let listener = HostListener(host: self)
        node.setListener(listener: listener)
        self.listener = listener
        self.node = node
        return node
    }

    /// Foreground-only lifecycle: the node runs only while the app is active.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            let app = UIApplication.shared
            var task: UIBackgroundTaskIdentifier = .invalid
            task = app.beginBackgroundTask(withName: "stop-freenet-node") {
                app.endBackgroundTask(task)
            }
            Task {
                await self.stop()
                app.endBackgroundTask(task)
            }
        case .active:
            guard welcomeSeen else { return }
            Task {
                let wasRunning = self.info != nil
                await self.start()
                if !wasRunning { self.sessionGeneration += 1 }
            }
        default:
            break
        }
    }

    // MARK: Events

    fileprivate func handle(_ event: NodeEvent) {
        if let node { status = node.status() }
    }

    // MARK: Web apps

    /// Wait until the node has joined the network through at least one peer.
    func waitForPeers(timeoutMs: UInt64 = 60_000) async -> Bool {
        guard let node else { return false }
        do {
            _ = try await node.waitForPeers(minPeers: 1, timeoutMs: timeoutMs)
            status = node.status()
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    func webURL(for app: DemoWebApp) -> URL? {
        guard let node, let text = try? node.webUrl(contractId: app.instanceId) else { return nil }
        return URL(string: text)
    }

    // MARK: Alerts

    func present(_ alert: InAppAlert) {
        guard UIApplication.shared.applicationState == .active else { return }
        self.alert = alert
    }

    func openAlert(_ alert: InAppAlert) {
        self.alert = nil
        selectedTab = alert.tab
        alert.open()
    }
}

/// Receives node events on a runtime thread and hands them to the main actor.
final class HostListener: NodeEventListener, @unchecked Sendable {
    private weak var host: NodeHost?

    init(host: NodeHost) {
        self.host = host
    }

    func onEvent(event: NodeEvent) {
        Task { @MainActor [weak host] in
            host?.handle(event)
        }
    }
}
