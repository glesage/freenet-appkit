import SwiftUI

@main
struct AppKitDemoApp: App {
    @StateObject private var host = NodeHost.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(host)
        }
        .onChange(of: scenePhase) { phase in
            host.scenePhaseChanged(phase)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var host: NodeHost

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $host.selectedTab) {
                WebAppScreen(app: .river)
                    .tabItem { Label("River", systemImage: "bubble.left.and.bubble.right") }
                    .tag(DemoTab.river)
                WebAppScreen(app: .atlas)
                    .tabItem { Label("Atlas", systemImage: "books.vertical") }
                    .tag(DemoTab.atlas)
            }
            if let alert = host.alert {
                AlertBanner(alert: alert) {
                    host.openAlert(alert)
                } dismiss: {
                    host.alert = nil
                }
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: host.alert?.id)
    }
}

struct AlertBanner: View {
    let alert: InAppAlert
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.headline).lineLimit(1)
                if !alert.body.isEmpty {
                    Text(alert.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss alert")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
