import SwiftUI

/// How far the web app has got once the node serves its page.
enum PageState: Equatable {
    /// The node is fetching the website container.
    case fetching
    /// The app's frame is loading its code.
    case starting
    /// The app has drawn something, or the node showed its own page.
    case shown
    case failed(String)
}

@MainActor
final class WebAppModel: ObservableObject {
    @Published var url: URL?
    @Published var phase = "Starting the node"
    @Published var page: PageState = .fetching

    func prepare(app: DemoWebApp, host: NodeHost) async {
        url = nil
        phase = "Starting the node"
        guard await host.start() != nil else {
            phase = "The node did not start.\n\(host.lastError ?? "")"
            return
        }
        phase = "Waiting for a peer"
        guard await host.waitForPeers() else {
            phase = "No peer answered.\n\(host.lastError ?? "")"
            return
        }
        page = .fetching
        url = host.webURL(for: app)
    }

    func pageText(app: DemoWebApp, host: NodeHost) -> String {
        switch page {
        case .fetching:
            return "Fetching \(app.name) from the network"
        case .starting:
            return "Starting \(app.name)"
        case .shown:
            return ""
        case .failed(let message):
            return "\(app.name) did not load.\n\(message)"
        }
    }
}

struct WebAppScreen: View {
    let app: DemoWebApp
    @EnvironmentObject var host: NodeHost
    @StateObject private var model = WebAppModel()

    var body: some View {
        ZStack {
            if let url = model.url {
                WebAppView(app: app, url: url, generation: host.sessionGeneration, model: model)
                    .ignoresSafeArea(edges: .bottom)
                if model.page != .shown {
                    LoadingView(
                        text: model.pageText(app: app, host: host),
                        failed: model.page != .fetching && model.page != .starting,
                        retry: { Task { await model.prepare(app: app, host: host) } })
                }
            } else {
                LoadingView(text: model.phase, failed: false, retry: nil)
            }
        }
        .task(id: host.sessionGeneration) {
            await model.prepare(app: app, host: host)
        }
    }
}

/// A spinner and a line of text over the whole screen, or the error and a
/// retry button once loading failed.
struct LoadingView: View {
    let text: String
    let failed: Bool
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if !failed { ProgressView() }
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if failed, let retry {
                Button("Try again", action: retry).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
