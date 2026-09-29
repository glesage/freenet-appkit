import SwiftUI

@main
struct AppKitDemoApp: App {
    @StateObject private var host = NodeHost.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ProcessClock.markAppInit()
        _ = NetworkPath.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(host)
                .onAppear {
                    ProcessClock.markFirstFrame()
                    Harness.startIfRequested(host: host)
                }
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
                BridgeTestScreen()
                    .tabItem { Label("Bridge", systemImage: "arrow.left.arrow.right") }
                    .tag(DemoTab.bridge)
                NativeRouteScreen()
                    .tabItem { Label("Native", systemImage: "swift") }
                    .tag(DemoTab.native)
                DiagnosticsScreen()
                    .tabItem { Label("Node", systemImage: "gauge") }
                    .tag(DemoTab.diagnostics)
            }
            if let prompt = host.harnessPrompt {
                Text(prompt)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
            } else if let alert = host.alert {
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

enum DemoTab: Hashable {
    case river, atlas, bridge, native, diagnostics
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
