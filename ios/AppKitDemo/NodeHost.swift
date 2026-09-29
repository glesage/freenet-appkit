import FreenetAppKit
import SwiftUI
import UIKit

/// How the demo's node reaches other peers.
enum NetworkProfile: String, CaseIterable, Identifiable {
    /// An isolated node on the phone, with River and Atlas preloaded from the
    /// app bundle. Nothing leaves the phone.
    case local
    /// Network mode through a gateway override, such as the isolated test
    /// gateway on the development Mac.
    case gateway
    /// Network mode through the public gateway index.
    case publicNetwork = "public"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "Local (offline)"
        case .gateway: return "Test gateway"
        case .publicNetwork: return "Public network"
        }
    }
}

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
    /// An instruction the harness shows the person holding the phone.
    @Published var harnessPrompt: String?
    @Published var profile: NetworkProfile {
        didSet { defaults.set(profile.rawValue, forKey: Keys.profile) }
    }
    @Published var gatewayText: String {
        didSet { defaults.set(gatewayText, forKey: Keys.gateway) }
    }
    @Published var alertGrant: AlertGrant {
        didSet { defaults.set(alertGrant.rawValue, forKey: Keys.alerts) }
    }
    @Published private(set) var lifecycleLog: [String] = []

    private(set) var node: MobileNode?
    let directories: NodeDirectories
    private var listener: HostListener?
    private var eventSinks: [UUID: (NodeEvent) -> Void] = [:]
    private var lifecycleSinks: [UUID: (LifecyclePhase) -> Void] = [:]
    private var preloaded: Set<String> = []
    private let defaults = UserDefaults.standard

    enum Keys {
        static let profile = "appkit.profile"
        static let gateway = "appkit.gateway"
        static let alerts = "appkit.alerts"
        static let backend = "appkit.backend"
        static let port = "appkit.lastPort"
    }

    private init() {
        directories = try! NodeDirectories.standard()
        profile = NetworkProfile(rawValue: defaults.string(forKey: Keys.profile) ?? "") ?? .local
        gatewayText = defaults.string(forKey: Keys.gateway) ?? ""
        alertGrant = AlertGrant(rawValue: defaults.string(forKey: Keys.alerts) ?? "") ?? .notAsked
    }

    // MARK: Settings

    var gatewayOverrides: [GatewayOverride] {
        gatewayText
            .split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .compactMap { line in
                let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { return nil }
                return GatewayOverride(address: parts[0], publicKeyHex: parts[1])
            }
    }

    var backendChoice: WasmBackendChoice? {
        switch defaults.string(forKey: Keys.backend) {
        case "cranelift": return .cranelift
        case "pulley": return .pulley
        default: return nil
        }
    }

    func settings(for profile: NetworkProfile) -> NodeSettings {
        let lastPort = UInt16(clamping: defaults.integer(forKey: Keys.port))
        switch profile {
        case .local:
            return directories.settings(
                mode: .local, preferredWsPort: lastPort == 0 ? nil : lastPort, wasmBackend: backendChoice)
        case .gateway:
            return directories.settings(
                mode: .network, gateways: gatewayOverrides,
                preferredWsPort: lastPort == 0 ? nil : lastPort, wasmBackend: backendChoice)
        case .publicNetwork:
            return directories.settings(
                mode: .network, preferredWsPort: lastPort == 0 ? nil : lastPort, wasmBackend: backendChoice)
        }
    }

    // MARK: Lifecycle

    /// Start the node for the current profile. Repeated calls return the
    /// running node.
    @discardableResult
    func start() async -> NodeInfo? {
        do {
            let node = try currentNode()
            let info = try await node.start()
            self.info = info
            self.status = node.status()
            self.lastError = nil
            defaults.set(Int(info.wsPort), forKey: Keys.port)
            log("started session \(info.session) on port \(info.wsPort) in \(Int(info.timings.totalMs)) ms")
            return info
        } catch {
            lastError = "\(error)"
            log("start failed: \(error)")
            return nil
        }
    }

    func stop() async {
        guard let node else { return }
        do {
            try await node.stop()
            log("stopped")
        } catch {
            lastError = "\(error)"
        }
        info = nil
        status = node.status()
    }

    /// Switch profile: stop the node, then start one with the new settings.
    func apply(profile newProfile: NetworkProfile) async {
        await stop()
        node?.setListener(listener: nil)
        node = nil
        preloaded = []
        profile = newProfile
        await start()
        sessionGeneration += 1
    }

    private func currentNode() throws -> MobileNode {
        if let node { return node }
        let node = try MobileNode(settings: settings(for: profile))
        let listener = HostListener(host: self)
        node.setListener(listener: listener)
        self.listener = listener
        self.node = node
        return node
    }

    /// Foreground-only lifecycle: the node runs only while the app is active.
    func scenePhaseChanged(_ phase: ScenePhase) {
        // Harness runs keep the node up unless the scenario measures the
        // lifecycle itself.
        if let scenario = UserDefaults.standard.string(forKey: "appkit.scenario"),
           !Harness.lifecycleScenarios.contains(scenario), phase == .background {
            return
        }
        switch phase {
        case .background:
            log("backgrounding")
            for sink in lifecycleSinks.values { sink(.backgrounding) }
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
            Task {
                let wasRunning = self.info != nil
                await self.start()
                if !wasRunning {
                    self.sessionGeneration += 1
                    for sink in self.lifecycleSinks.values { sink(.resumed) }
                    self.log("resumed with a fresh session")
                }
            }
        default:
            break
        }
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lifecycleLog.append("\(stamp) \(line)")
        if lifecycleLog.count > 50 { lifecycleLog.removeFirst(lifecycleLog.count - 50) }
        NSLog("AppKitDemo: %@", line)
    }

    // MARK: Events

    fileprivate func handle(_ event: NodeEvent) {
        if let node { status = node.status() }
        for sink in eventSinks.values { sink(event) }
    }

    func addEventSink(_ sink: @escaping (NodeEvent) -> Void) -> UUID {
        let id = UUID()
        eventSinks[id] = sink
        return id
    }

    func addLifecycleSink(_ sink: @escaping (LifecyclePhase) -> Void) -> UUID {
        let id = UUID()
        lifecycleSinks[id] = sink
        return id
    }

    func removeSink(_ id: UUID) {
        eventSinks[id] = nil
        lifecycleSinks[id] = nil
    }

    // MARK: Web apps

    /// Wait for a peer in network mode. Local mode has none to wait for.
    func waitForPeers(timeoutMs: UInt64 = 60_000) async -> Bool {
        guard let node, profile != .local else { return true }
        do {
            _ = try await node.waitForPeers(minPeers: 1, timeoutMs: timeoutMs)
            status = node.status()
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    /// In local mode, store the app's website container from the app bundle
    /// so the web app loads with no network.
    func preloadIfLocal(_ app: DemoWebApp) async throws {
        guard profile == .local, let info, !preloaded.contains(app.instanceId) else { return }
        let client = try await connectClient(wsPort: info.wsPort)
        do {
            _ = try await client.get(instanceId: app.instanceId, returnCode: false, subscribe: false, timeoutMs: 10_000)
        } catch {
            let files = try AppResources.webapp(app.resourceName)
            _ = try await client.put(
                code: files.code, parameters: files.params, state: files.state,
                subscribe: false, timeoutMs: 60_000)
        }
        preloaded.insert(app.instanceId)
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
