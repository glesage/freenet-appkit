import SwiftUI

/// How far the web app has got once the node serves its page.
enum PageState: Equatable {
    /// The node is fetching the website container.
    case fetching
    /// The app's frame is loading its code.
    case starting
    /// The app has drawn something, or the node showed its own page.
    case shown
    /// The last page stays on screen while the node starts a new session and
    /// the new page loads behind it.
    case reconnecting
    case failed(String)
}

@MainActor
final class WebAppModel: ObservableObject {
    @Published var url: URL?
    /// What the loading view shows until the node serves the page.
    @Published var status = LoadStatus(title: LoadMessages.starting)
    @Published var page: PageState = .fetching
    /// Increases every time `url` is set, so the web view loads again even
    /// when the new session serves the same URL.
    @Published private(set) var loadID = 0

    /// The node session the page on screen was loaded for.
    private(set) var loadedSession: UInt64?

    func prepare(app: HostedApp, host: NodeHost) async {
        let reconnecting = url != nil && (page == .shown || page == .reconnecting)
        // In the background the page stays, its session already ended; the
        // next session loads it again.
        guard host.wantsNode else {
            if reconnecting { page = .reconnecting }
            return
        }
        if reconnecting {
            page = .reconnecting
        } else {
            url = nil
        }
        status = LoadStatus(title: LoadMessages.starting)
        guard let info = await host.session() else {
            if host.wantsNode { fail(.error(LoadMessages.notStarted, detail: host.lastError)) }
            return
        }
        // A saved page opens before the node joins the network.
        if !host.hasSavedPage {
            status = LoadStatus(title: LoadMessages.connecting)
            let slow = Task { [weak self] in
                try? await Task.sleep(nanoseconds: LoadMessages.slowAfterSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self, self.status.title == LoadMessages.connecting else { return }
                self.status = LoadStatus(title: LoadMessages.connectingSlow)
            }
            let joined = await host.waitForPeers()
            slow.cancel()
            guard joined else {
                fail(.error(LoadMessages.unreachable, detail: host.lastError))
                return
            }
        }
        guard host.info?.session == info.session else { return }
        if !reconnecting { page = .fetching }
        loadedSession = info.session
        url = host.webURL()
        loadID += 1
    }

    /// Replace any page on screen with the full-screen error.
    private func fail(_ error: LoadStatus) {
        url = nil
        page = .fetching
        status = error
    }

    func pageStatus(app: HostedApp) -> LoadStatus {
        switch page {
        case .fetching:
            return LoadStatus(title: LoadMessages.downloading(app))
        case .starting:
            return LoadStatus(title: LoadMessages.opening(app))
        case .shown, .reconnecting:
            return LoadStatus(title: "")
        case .failed(let message):
            return .error(LoadMessages.pageFailed(app), detail: message)
        }
    }
}

struct WebAppScreen: View {
    let app: HostedApp
    @EnvironmentObject var host: NodeHost
    @StateObject private var model = WebAppModel()

    var body: some View {
        ZStack {
            if let url = model.url {
                WebAppView(
                    app: app, url: url, generation: model.loadID, session: model.loadedSession, model: model)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(model.page != .reconnecting)
                    .opacity(model.page == .reconnecting ? 0.6 : 1)
                switch model.page {
                case .shown:
                    EmptyView()
                case .reconnecting:
                    ReconnectingPill()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                default:
                    LoadingView(status: model.pageStatus(app: app), retry: retry)
                }
            } else {
                LoadingView(status: model.status, retry: retry)
            }
        }
        .task(id: host.welcomeSeen ? "\(host.sessionGeneration)-\(host.failedStarts)" : "") {
            guard host.welcomeSeen else { return }
            await model.prepare(app: app, host: host)
        }
        .overlay(alignment: .bottom) {
            if !host.networkAvailable && model.page == .shown {
                OfflinePill().padding(.bottom, 12)
            }
        }
    }

    private func retry() {
        Task { await model.prepare(app: app, host: host) }
    }
}

/// Shown over the page while the device has no network. Saved content stays
/// readable; changes reach the network when it returns.
struct OfflinePill: View {
    var body: some View {
        Label("Offline", systemImage: "wifi.slash")
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

/// A small capsule over the last page while the node reconnects.
struct ReconnectingPill: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Reconnecting").font(.subheadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 1)
        .accessibilityElement(children: .combine)
    }
}
