import Foundation

/// A tab in the app's tab bar.
enum DemoTab: Hashable {
    case river, atlas
}

/// A web app the app loads from a website container on the network.
struct DemoWebApp: Hashable {
    let name: String
    let instanceId: String
    let tab: DemoTab

    static let river = DemoWebApp(
        name: "River", instanceId: "raAqMhMG7KUpXBU2SxgCQ3Vh4PYjttxdSWd9ftV7RLv", tab: .river)
    static let atlas = DemoWebApp(
        name: "Atlas", instanceId: "771DvtPMwt2PumPyrFvsz7fpvU1gogcmb5qtS1yYEEH9", tab: .atlas)
    static let all = [river, atlas]
}
