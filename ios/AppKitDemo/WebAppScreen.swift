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
    /// What the loading view shows until the node serves the page.
    @Published var status = LoadStatus(title: LoadMessages.starting)
    @Published var page: PageState = .fetching

    func prepare(app: DemoWebApp, host: NodeHost) async {
        url = nil
        status = LoadStatus(title: LoadMessages.starting)
        guard await host.start() != nil else {
            status = .error(LoadMessages.notStarted, detail: host.lastError)
            return
        }
        status = LoadStatus(title: LoadMessages.connecting)
        let slow = Task { [weak self] in
            try? await Task.sleep(nanoseconds: LoadMessages.slowAfterSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.status.title == LoadMessages.connecting else { return }
            self.status = LoadStatus(title: LoadMessages.connectingSlow)
        }
        let joined = await host.waitForPeers()
        slow.cancel()
        guard joined else {
            status = .error(LoadMessages.unreachable, detail: host.lastError)
            return
        }
        page = .fetching
        url = host.webURL(for: app)
    }

    func pageStatus(app: DemoWebApp) -> LoadStatus {
        switch page {
        case .fetching:
            return LoadStatus(title: LoadMessages.downloading(app))
        case .starting:
            return LoadStatus(title: LoadMessages.opening(app))
        case .shown:
            return LoadStatus(title: "")
        case .failed(let message):
            return .error(LoadMessages.pageFailed(app), detail: message)
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
                    LoadingView(status: model.pageStatus(app: app), retry: retry)
                }
            } else {
                LoadingView(status: model.status, retry: retry)
            }
        }
        .task(id: host.sessionGeneration) {
            await model.prepare(app: app, host: host)
        }
    }

    private func retry() {
        Task { await model.prepare(app: app, host: host) }
    }
}
