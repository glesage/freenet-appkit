import FreenetAppKit
import Network
import SwiftUI
import UIKit

/// A foreground message alert from the hosted app.
struct InAppAlert: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let open: () -> Void
}

/// The user's answer to "show message alerts", kept for the hosted app only.
enum AlertGrant: String {
    case notAsked = "default", granted, denied
}

/// Owns the hosted app's embedded node and runs it only while the app is in
/// the foreground.
///
/// One reconciler moves the node towards what the app wants (running in the
/// foreground, stopped in the background), one step at a time, so a start
/// and a stop never interleave. Every stop ends the session: web views and
/// prompts bound to it are discarded before the next session's page loads.
@MainActor
final class NodeHost: ObservableObject {
    static let shared = NodeHost()

    let app = HostedApp.current

    @Published private(set) var status: NodeStatus?
    @Published private(set) var info: NodeInfo?
    @Published private(set) var lastError: String?
    /// Increases whenever a session ends, so web views reload with new
    /// authority and prompts from the old session are closed.
    @Published private(set) var sessionGeneration = 0
    /// Increases whenever a start fails, so a waiting page shows the error.
    @Published private(set) var failedStarts = 0
    /// The device has a usable network path.
    @Published private(set) var networkAvailable = true
    @Published var alert: InAppAlert?
    @Published var alertGrant: AlertGrant {
        didSet { defaults.set(alertGrant.rawValue, forKey: app.key("alerts")) }
    }
    /// The user has tapped "Continue" on the welcome screen. The node starts
    /// only after that, so the local network prompt comes after the welcome.
    @Published var welcomeSeen: Bool {
        didSet {
            defaults.set(welcomeSeen, forKey: app.key("welcomeSeen"))
            reconcile()
        }
    }

    private(set) var node: MobileNode?
    /// `nil` when the node's folders could not be created; `start()` then
    /// reports the error instead of starting.
    let directories: NodeDirectories?
    private var listener: HostListener?
    private let defaults = UserDefaults.standard
    private let pathMonitor = NWPathMonitor()

    /// What the app wants: the node running (foreground) or stopped.
    private var wantRunning = false
    private var reconciler: Task<Void, Never>?
    /// Restarts after a network change, within the current minute.
    private var networkRestarts: [Date] = []

    /// At most this many node restarts per minute when the network comes back
    /// and the node has no peers.
    static let maxNetworkRestartsPerMinute = 2

    private init() {
        directories = try? NodeDirectories.standard(folder: HostedApp.current.storageFolder)
        let app = HostedApp.current
        alertGrant = AlertGrant(rawValue: defaults.string(forKey: app.key("alerts")) ?? "") ?? .notAsked
        welcomeSeen = defaults.bool(forKey: app.key("welcomeSeen"))
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available: available) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "appkit.path"))
    }

    // MARK: Settings

    /// The node always joins the public network on Pulley. It asks for the
    /// last WebSocket port again, so web app data stored per origin stays
    /// reachable.
    private func settings(in directories: NodeDirectories) -> NodeSettings {
        directories.settings(mode: .network, preferredWsPort: preferredPort(), wasmBackend: .pulley)
    }

    /// The loopback port this installation asks for on every start, so web
    /// app storage keeps one origin. Chosen once, before the first start.
    private func preferredPort() -> UInt16 {
        let saved = defaults.integer(forKey: app.key("port"))
        if (1024...65535).contains(saved) { return UInt16(saved) }
        let port = UInt16.random(in: 49152...65000)
        defaults.set(Int(port), forKey: app.key("port"))
        return port
    }

    // MARK: Lifecycle

    /// The app is in the foreground and past the welcome screen.
    var wantsNode: Bool { wantRunning && welcomeSeen }

    /// The running session, started if the app wants one. `nil` in the
    /// background or when the start failed (see `lastError`). Never runs while
    /// a stop is in progress.
    func session() async -> NodeInfo? {
        if let info, reconciler == nil { return info }
        reconcile()
        await reconciler?.value
        return info
    }

    private func startNode() async -> NodeInfo? {
        guard let directories else {
            lastError = "Freenet could not create its folders on this device."
            return nil
        }
        do {
            let node = try currentNode(directories: directories)
            let info = try await node.start()
            guard info.wasmBackend == .pulley, buildInfo().availableBackends.contains(.pulley) else {
                try? await node.stop()
                lastError = "This build does not run contracts on Pulley (got \(info.wasmBackend))."
                return nil
            }
            self.info = info
            self.status = node.status()
            self.lastError = nil
            return info
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    private func stopNode() async {
        guard let node else { return }
        // The session ends before the stop: nothing bound to it may act.
        if info != nil { sessionGeneration += 1 }
        info = nil
        do {
            try await node.stop()
        } catch MobileError.IncompleteShutdown(let exited, let released, let ms) {
            lastError = "The node stopped incompletely after \(ms) ms (exited: \(exited), port released: \(released))."
        } catch {
            lastError = "\(error)"
        }
        status = node.status()
    }

    /// Move the node towards `wantRunning`, one step at a time.
    private func reconcile() {
        guard reconciler == nil else { return }
        reconciler = Task { [weak self] in
            while let self {
                let want = self.wantsNode
                let running = self.info != nil
                if want == running { break }
                if want {
                    if await self.startNode() == nil {
                        self.failedStarts += 1
                        break
                    }
                    self.sessionGeneration += 1
                } else {
                    await self.stopNode()
                }
            }
            self?.reconciler = nil
        }
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
            wantRunning = false
            let app = UIApplication.shared
            var task: UIBackgroundTaskIdentifier = .invalid
            task = app.beginBackgroundTask(withName: "stop-freenet-node") {
                app.endBackgroundTask(task)
            }
            reconcile()
            Task {
                await self.reconciler?.value
                app.endBackgroundTask(task)
            }
        case .active:
            wantRunning = true
            reconcile()
        default:
            break
        }
    }

    /// The network came back: the node reconnects by itself, but a node that
    /// still has no peers a while later restarts, a bounded number of times.
    private func networkChanged(available: Bool) {
        let cameBack = available && !networkAvailable
        networkAvailable = available
        guard cameBack else { return }
        Task {
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            guard wantRunning, info != nil, (status?.connectedPeers ?? 0) == 0 else { return }
            let now = Date()
            networkRestarts = networkRestarts.filter { now.timeIntervalSince($0) < 60 }
            guard networkRestarts.count < Self.maxNetworkRestartsPerMinute else { return }
            networkRestarts.append(now)
            await stopNode()
            reconcile()
        }
    }

    // MARK: Events

    fileprivate func handle(_ event: NodeEvent) {
        if let node { status = node.status() }
        if case .exited = event {
            info = nil
            sessionGeneration += 1
        }
    }

    // MARK: Web app

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

    /// The node unpacked this app's website container on an earlier visit,
    /// so it can serve the page before it joins the network.
    var hasSavedPage: Bool {
        guard let directories else { return false }
        let cache = directories.cache.appendingPathComponent("network/webapp_cache", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        return entries.contains { $0.hasPrefix(app.instanceId) }
    }

    func webURL() -> URL? {
        guard let node, let text = try? node.webUrl(contractId: app.instanceId) else { return nil }
        return URL(string: text)
    }

    /// The origin the current session serves the app from.
    var origin: (host: String, port: Int)? {
        info.map { ("127.0.0.1", Int($0.wsPort)) }
    }

    // MARK: Alerts

    func present(_ alert: InAppAlert) {
        guard UIApplication.shared.applicationState == .active, alertGrant == .granted else { return }
        self.alert = alert
    }

    func openAlert(_ alert: InAppAlert) {
        self.alert = nil
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
