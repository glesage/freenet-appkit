import Foundation
import Network

/// The phone's current network path, from `NWPathMonitor`.
final class NetworkPath: @unchecked Sendable {
    static let shared = NetworkPath()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.path = path }
        }
        monitor.start(queue: DispatchQueue(label: "appkit.network-path"))
    }

    /// `wifi`, `cellular`, `wired`, `other`, `none`, or `unknown` before the
    /// first reading.
    var kind: String {
        lock.withLock {
            guard let path else { return "unknown" }
            guard path.status == .satisfied else { return "none" }
            if path.usesInterfaceType(.wifi) { return "wifi" }
            if path.usesInterfaceType(.cellular) { return "cellular" }
            if path.usesInterfaceType(.wiredEthernet) { return "wired" }
            return "other"
        }
    }

    var summary: [String: Any] {
        lock.withLock {
            guard let path else { return ["status": "unknown"] }
            return [
                "status": "\(path.status)",
                "expensive": path.isExpensive,
                "constrained": path.isConstrained,
                "interfaces": path.availableInterfaces.map { "\($0.type)" },
            ]
        }
    }
}
