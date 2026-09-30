import SwiftUI

/// A spinner and a line of text over the whole screen, or the error with
/// "Try again" and "Details" buttons once loading failed.
struct LoadingView: View {
    let status: LoadStatus
    let retry: (() -> Void)?
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 12) {
            if !status.failed { ProgressView() }
            Text(status.title)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if status.failed {
                if let retry {
                    Button("Try again", action: retry).buttonStyle(.bordered)
                }
                if let detail = status.detail, !detail.isEmpty {
                    Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                        .font(.footnote)
                    if showDetails {
                        Text(detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .onChange(of: status) { _ in showDetails = false }
    }
}
