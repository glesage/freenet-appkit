import FreenetAppKit
import SwiftUI

struct NativeRouteScreen: View {
    @State private var checks: [NativeRoute.Check] = []
    @State private var samples: [NativeRoute.CopySample] = []
    @State private var running = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Swift calls the node directly through the SDK: put, get, update and subscribe on a local fixture node, compared with the desktop values.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Run the native route") { Task { await run() } }
                        .disabled(running)
                    if running {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Storing and reading contracts on the fixture node").foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section("Error") { Text(error).foregroundStyle(.red) }
                }
                if !checks.isEmpty {
                    Section("Checks against desktop") {
                        ForEach(checks, id: \.name) { check in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(check.name, systemImage: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(check.passed ? .green : .red)
                                Text(check.actual).font(.caption.monospaced()).lineLimit(2)
                            }
                        }
                    }
                }
                if !samples.isEmpty {
                    Section("Large records") {
                        ForEach(samples, id: \.bytes) { sample in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(sample.bytes), countStyle: .binary)).font(.headline)
                                Text(String(format: "bindings %.1f ms · put %.1f ms (node %.1f) · get %.1f ms (node %.1f)",
                                            sample.echoMs, sample.putMs, sample.putNodeMs, sample.getMs, sample.getNodeMs))
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
            }
            .navigationTitle("Native route")
        }
    }

    private func run() async {
        running = true
        error = nil
        defer { running = false }
        do {
            let expected = try Harness.expectedFixtureValues()
            checks = try await NativeRoute.run(expected: expected)
            samples = try await NativeRoute.largeRecords(sizes: [16 << 10, 1 << 20, 8 << 20])
        } catch {
            self.error = "\(error)"
        }
    }
}
