import SwiftUI
import UIKit

/// Shown once, on first start, before the node starts. "Continue" stores
/// that the user has seen it.
struct WelcomeScreen: View {
    let onContinue: () -> Void

    private var terms: AttributedString {
        (try? AttributedString(markdown: "By continuing you agree to the [Terms](\(AppInfo.termsURL.absoluteString)).")
        ) ?? AttributedString("By continuing you agree to the Terms.")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    if let icon = Self.appIcon {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .accessibilityHidden(true)
                    }
                    Text(AppInfo.fullName)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Chat with River and browse Atlas, served by Freenet running on your phone.")
                        Text("Freenet connects directly to other people's devices. It runs only while this app is open.")
                        Text("What you post is shared with other people on the network.")
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 28)
                .padding(.top, 64)
                .padding(.bottom, 24)
            }
            VStack(spacing: 14) {
                Text(terms)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Link("Support", destination: AppInfo.supportURL)
                    .font(.footnote)
                Button(action: onContinue) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemBackground))
    }

    /// The home screen icon, read from the icon files the asset catalog
    /// compiles into the bundle.
    private static var appIcon: UIImage? {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let name = (primary["CFBundleIconFiles"] as? [String])?.last
        else { return nil }
        return UIImage(named: name)
    }
}
