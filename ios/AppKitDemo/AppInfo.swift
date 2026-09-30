import Foundation

/// The app's names and the links shown on the welcome screen. `AppInfo.kt` in
/// the Android app has the same values.
enum AppInfo {
    /// The home screen name, `AppKit`, read from the bundle.
    static var shortName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AppKit"
    }
    static let fullName = "Freenet AppKit"
    static let termsURL = URL(string: "https://freenet.org/terms")!
    static let supportURL = URL(string: "https://freenet.org/support")!
}
