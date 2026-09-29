import Foundation

/// Where an iOS app keeps the embedded node's files.
///
/// Stores live in Application Support, which iOS keeps across launches and
/// app updates and moves with the app's container. Logs and unpacked web apps
/// live in Caches, which iOS may clear when the device runs low on space.
public struct NodeDirectories {
    public let data: URL
    public let config: URL
    public let logs: URL
    public let cache: URL

    public static func standard(folder: String = "freenet") throws -> NodeDirectories {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent(folder, isDirectory: true)
        let caches = try fm.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent(folder, isDirectory: true)
        let dirs = NodeDirectories(
            data: support.appendingPathComponent("data", isDirectory: true),
            config: support.appendingPathComponent("config", isDirectory: true),
            logs: caches.appendingPathComponent("logs", isDirectory: true),
            cache: caches.appendingPathComponent("cache", isDirectory: true)
        )
        for url in [dirs.data, dirs.config, dirs.logs, dirs.cache] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return dirs
    }

    /// Settings for a node in `mode`, rooted in these directories.
    public func settings(
        mode: NodeMode,
        gateways: [GatewayOverride] = [],
        preferredWsPort: UInt16? = nil,
        wasmBackend: WasmBackendChoice? = nil
    ) -> NodeSettings {
        NodeSettings(
            dataDir: data.path,
            configDir: config.path,
            logDir: logs.path,
            cacheDir: cache.path,
            mode: mode,
            preferredWsPort: preferredWsPort,
            networkPort: nil,
            gateways: gateways,
            wasmBackend: wasmBackend,
            logFilter: nil,
            moduleCacheBudgetBytes: nil,
            maxHostingStorageBytes: nil,
            maxHostingDiskBytes: nil
        )
    }
}
