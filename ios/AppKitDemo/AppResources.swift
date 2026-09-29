import FreenetAppKit
import Foundation

/// A web app the demo loads from a website container.
struct DemoWebApp: Hashable {
    let name: String
    let instanceId: String
    /// File prefix of the container in `AppKitResources/webapps/`.
    let resourceName: String
    let tab: DemoTab

    static let river = DemoWebApp(
        name: "River", instanceId: "raAqMhMG7KUpXBU2SxgCQ3Vh4PYjttxdSWd9ftV7RLv",
        resourceName: "river", tab: .river)
    static let atlas = DemoWebApp(
        name: "Atlas", instanceId: "771DvtPMwt2PumPyrFvsz7fpvU1gogcmb5qtS1yYEEH9",
        resourceName: "atlas", tab: .atlas)
    static let all = [river, atlas]
}

/// Files `scripts/prepare-resources.sh` copies into the app's
/// `AppKitResources` folder.
enum AppResources {
    struct Missing: LocalizedError {
        let path: String
        var errorDescription: String? { "\(path) is not in the app bundle; run scripts/prepare-resources.sh" }
    }

    static var root: URL {
        Bundle.main.resourceURL!.appendingPathComponent("AppKitResources", isDirectory: true)
    }

    static func data(_ relative: String) throws -> Data {
        let url = root.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url) else { throw Missing(path: relative) }
        return data
    }

    static func webapp(_ name: String) throws -> (code: Data, params: Data, state: Data) {
        (
            try data("webapps/\(name).code.wasm"),
            try data("webapps/\(name).params"),
            try data("webapps/\(name).state")
        )
    }

    static func text(_ relative: String) throws -> String {
        String(decoding: try data(relative), as: UTF8.self)
    }

    static var protocolFixtures: String {
        get throws { try text("protocol-fixtures.json") }
    }

    static var bridgeTestBundle: URL {
        root.appendingPathComponent("bridge-test", isDirectory: true)
    }

    /// Real contracts compiled in the conformance run: River's room contract,
    /// Atlas's index contract and the website container contract.
    static func conformanceModules() -> [NamedModule] {
        [
            ("river_room_contract", "contracts/river-room-contract.wasm"),
            ("atlas_index_contract", "contracts/atlas-index-contract.wasm"),
            ("web_container_contract", "webapps/river.code.wasm"),
        ].compactMap { name, path in
            guard let wasm = try? data(path) else { return nil }
            return NamedModule(name: name, wasm: wasm, parameters: Data())
        }
    }
}
