import FreenetAppKit
import SwiftUI

struct DiagnosticsScreen: View {
    @EnvironmentObject var host: NodeHost
    @State private var output = ""
    @State private var busy = false
    private let build = buildInfo()

    var body: some View {
        NavigationStack {
            Form {
                Section("Node") {
                    LabeledContent("State", value: host.status.map { "\($0.state)" } ?? "not started")
                    LabeledContent("Port", value: host.info.map { String($0.wsPort) } ?? "–")
                    LabeledContent("Session", value: host.info.map { String($0.session) } ?? "–")
                    LabeledContent("Peers", value: host.status.map { String($0.connectedPeers) } ?? "–")
                    LabeledContent("Wasm backend", value: host.info.map { "\($0.wasmBackend)" } ?? "\(build.defaultBackend)")
                    if let error = host.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Start") { Task { await host.start() } }
                        Spacer()
                        Button("Stop", role: .destructive) { Task { await host.stop() } }
                    }
                }
                Section {
                    Picker("Network", selection: Binding(
                        get: { host.profile },
                        set: { profile in Task { await host.apply(profile: profile) } }
                    )) {
                        ForEach(NetworkProfile.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Gateway: ip:port,public-key-hex", text: $host.gatewayText, axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Network")
                } footer: {
                    Text("The node runs only while this app is open. It stops when the app moves to the background and starts a fresh session when the app returns.")
                }
                Section {
                    LabeledContent("Message alerts", value: host.alertGrant.rawValue)
                    Button("Ask again") { host.alertGrant = .notAsked }
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Message alerts appear only while this app is open. Messages that arrive while it is closed show up the next time you open it.")
                }
                Section("Checks") {
                    Button("Wasm backend conformance") { run { await conformance() } }
                    Button("Protocol fixtures") { run { await fixtures() } }
                    Button("Process metrics") { run { processMetricsJson(metrics: processMetrics()) } }
                        .disabled(busy)
                    if busy { ProgressView() }
                    if !output.isEmpty {
                        Text(output).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section("Build") {
                    LabeledContent("Core", value: "\(build.coreVersion) \(build.coreRevision.prefix(12))")
                    LabeledContent("stdlib", value: build.stdlibVersion)
                    LabeledContent("wasmtime", value: build.wasmtimeVersion)
                    LabeledContent("UniFFI", value: build.uniffiVersion)
                    LabeledContent("Target", value: build.target)
                }
                Section("Lifecycle") {
                    ForEach(host.lifecycleLog.reversed(), id: \.self) { Text($0).font(.caption2.monospaced()) }
                }
            }
            .navigationTitle("Node")
        }
    }

    private func run(_ work: @escaping @MainActor () async -> String) {
        busy = true
        Task {
            output = await work()
            busy = false
        }
    }

    private func conformance() async -> String {
        let report = await runBackendConformance(extraModules: AppResources.conformanceModules(), includeTimeout: false)
        let failed = report.cases.filter { !$0.passed }
        let lines = report.cases.map { "\($0.passed ? "✓" : "✗") \($0.backend) \($0.name) \(String(format: "%.1f", $0.elapsedMs)) ms" }
        return (report.passed ? "passed" : "\(failed.count) failed") + "\n" + lines.joined(separator: "\n")
    }

    private func fixtures() async -> String {
        do {
            let expected = try AppResources.protocolFixtures
            let report = try await FixtureNode.run { info in
                try await verifyFixtures(expectedJson: expected, wsPort: info.wsPort)
            }
            let lines = report.checks.map { "\($0.passed ? "✓" : "✗") \($0.name)" }
            return (report.passed ? "passed" : "failed") + "\n" + lines.joined(separator: "\n")
        } catch {
            return "\(error)"
        }
    }
}
