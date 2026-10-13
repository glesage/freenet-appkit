import Foundation

/// The one web app this installation hosts. Each build hosts exactly one: the
/// `AppKitApplication` Info.plist key, set from the `APPKIT_APPLICATION` build
/// setting, picks it. Its node, stores, web data and consent records belong to
/// that app alone. `HostedApp.kt` in the Android app has the same values.
struct HostedApp: Hashable {
    /// Stable identifier, used for storage folders and preference keys.
    let id: String
    let name: String
    /// The website container the node serves the app from.
    let instanceId: String

    static let river = HostedApp(
        id: "river", name: "River", instanceId: "raAqMhMG7KUpXBU2SxgCQ3Vh4PYjttxdSWd9ftV7RLv")
    static let atlas = HostedApp(
        id: "atlas", name: "Atlas", instanceId: "771DvtPMwt2PumPyrFvsz7fpvU1gogcmb5qtS1yYEEH9")
    static let all = [river, atlas]

    /// The app this build hosts. River when the key is missing or unknown.
    static let current: HostedApp = {
        let id = Bundle.main.object(forInfoDictionaryKey: "AppKitApplication") as? String
        return all.first { $0.id == id } ?? river
    }()

    /// Folder for this app's node files, in Application Support and Caches.
    var storageFolder: String { "freenet-\(id)" }

    /// A preference key in this app's own namespace.
    func key(_ name: String) -> String { "appkit.\(id).\(name)" }
}
