import Foundation

/// Plain-language text for the loading view. `LoadMessages.kt` in the Android
/// app has the same text.
enum LoadMessages {
    static let starting = "Starting Freenet"
    static let connecting = "Connecting to the Freenet network"
    static let connectingSlow =
        "Connecting to the Freenet network. The first connection can take up to a minute."
    /// How long the peer wait shows `connecting` before `connectingSlow`.
    static let slowAfterSeconds: UInt64 = 10
    static let notStarted = "Freenet could not start."
    static let unreachable =
        "Freenet could not reach the network. Check your internet connection. "
        + "Some Wi-Fi networks block Freenet's traffic; mobile data may work."

    static func downloading(_ app: DemoWebApp) -> String { "Downloading \(app.name)" }
    static func opening(_ app: DemoWebApp) -> String { "Opening \(app.name)" }
    static func pageFailed(_ app: DemoWebApp) -> String { "\(app.name) could not open." }
}

/// What the loading view shows: a title, and for errors the technical detail
/// behind a "Details" button.
struct LoadStatus: Equatable {
    var title: String
    var detail: String?
    var failed = false

    static func error(_ title: String, detail: String?) -> LoadStatus {
        LoadStatus(title: title, detail: detail, failed: true)
    }
}
