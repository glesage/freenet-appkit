import FreenetAppKit
import SwiftUI
import UIKit

/// Runs a measurement scenario chosen by launch arguments and writes its
/// result, so the host-side harness can drive the app:
///
///     xcrun simctl launch --console <device> org.freenet.appkit.demo \
///         -appkit.scenario conformance -appkit.exitWhenDone YES
///
/// The result goes to `Documents/appkit-results/<scenario>.json` and to the
/// console as one `APPKIT_RESULT {...}` line. The Android demo writes the
/// same fields.
@MainActor
enum Harness {
    private static var started = false

    static let scenarios = [
        "conformance", "fixtures", "native", "startup", "lifecycle", "bridge", "river", "atlas", "storage",
    ]

    /// Scenarios that need the real foreground lifecycle while they run.
    static let lifecycleScenarios: Set<String> = ["resume"]

    static func startIfRequested(host: NodeHost) {
        guard !started, let scenario = UserDefaults.standard.string(forKey: "appkit.scenario") else { return }
        started = true
        // Keep the screen on: a locked phone refuses the harness's next launch.
        UIApplication.shared.isIdleTimerDisabled = true
        Task { @MainActor in
            let names = scenario == "all" ? scenarios : scenario.split(separator: ",").map(String.init)
            for name in names {
                let result = await run(name, host: host)
                write(name, result)
            }
            if UserDefaults.standard.bool(forKey: "appkit.exitWhenDone") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit(0)
            }
        }
    }

    // MARK: Scenarios

    static func run(_ scenario: String, host: NodeHost) async -> [String: Any] {
        var out: [String: Any] = [
            "scenario": scenario,
            "platform": "ios",
            "device": deviceInfo(),
            "build": json(buildInfoJson()),
            "profile": host.profile.rawValue,
            "started_at_ms": ProcessClock.nowMs(),
        ]
        do {
            switch scenario {
            case "conformance":
                let report = await runBackendConformance(
                    extraModules: AppResources.conformanceModules(), includeTimeout: true)
                out["passed"] = report.passed
                out["result"] = json(conformanceReportJson(report: report))
            case "fixtures":
                let expected = try AppResources.protocolFixtures
                let report = try await FixtureNode.run { info in
                    try await verifyFixtures(expectedJson: expected, wsPort: info.wsPort)
                }
                out["passed"] = report.passed
                out["result"] = json(fixtureReportJson(report: report))
            case "native":
                let checks = try await NativeRoute.run(expected: try expectedFixtureValues())
                let samples = try await NativeRoute.largeRecords(
                    sizes: [16 << 10, 256 << 10, 1 << 20, 4 << 20, 16 << 20, 32 << 20])
                out["passed"] = checks.allSatisfy(\.passed) && samples.allSatisfy(\.intact)
                out["result"] = ["checks": encode(checks), "large_records": encode(samples)]
            case "startup":
                out["result"] = try await startup(host: host)
            case "lifecycle":
                out["result"] = try await lifecycle(host: host)
            case "bridge":
                let report = try await bridge(host: host)
                out["passed"] = report["passed"] as? Bool ?? false
                out["result"] = report
            case "river":
                out["result"] = await webApp(.river, host: host)
            case "atlas":
                out["result"] = await webApp(.atlas, host: host)
            case "storage":
                out["result"] = storage(host: host)
            case "watch":
                out["result"] = await watch(host: host)
            case "resume":
                out["result"] = try await resume(host: host)
            case "transition":
                out["result"] = try await transition(host: host)
            case "offline_start":
                out["result"] = try await offlineStart(host: host)
            case "cellular_start":
                out["result"] = try await cellularStart(host: host)
            case "throughput":
                let result = try await throughput()
                out["passed"] = result["error"] == nil
                out["result"] = result
            case "alerts":
                let result = try await alerts(host: host)
                out["passed"] = result["opened"] as? Bool ?? false
                out["result"] = result
            case "wasm_instances":
                let result = try await wasmInstances()
                out["passed"] = result["error"] == nil
                out["result"] = result
            default:
                out["error"] = "unknown scenario \(scenario)"
            }
        } catch {
            out["error"] = "\(error)"
            out["passed"] = false
        }
        out["finished_at_ms"] = ProcessClock.nowMs()
        out["metrics"] = json(processMetricsJson(metrics: processMetrics()))
        return out
    }

    /// Process start to first frame, then the node's first and second start
    /// in this process.
    static func startup(host: NodeHost) async throws -> [String: Any] {
        var result: [String: Any] = [
            "process_to_app_init_ms": ProcessClock.sinceProcessStart(ProcessClock.appInitMs) as Any,
            "process_to_first_frame_ms": ProcessClock.sinceProcessStart(ProcessClock.firstFrameMs) as Any,
        ]
        await host.stop()
        let coldStart = Date()
        guard let cold = await host.start() else { throw HarnessError(host.lastError ?? "start failed") }
        result["node_first_start_ms"] = Date().timeIntervalSince(coldStart) * 1000
        result["node_first_start"] = json(nodeInfoJson(info: cold))
        let stopStart = Date()
        await host.stop()
        result["node_stop_ms"] = Date().timeIntervalSince(stopStart) * 1000
        let warmStart = Date()
        guard let warm = await host.start() else { throw HarnessError(host.lastError ?? "restart failed") }
        result["node_restart_ms"] = Date().timeIntervalSince(warmStart) * 1000
        result["node_restart"] = json(nodeInfoJson(info: warm))
        return result
    }

    /// Background and foreground the node the way the app does, three times.
    static func lifecycle(host: NodeHost) async throws -> [String: Any] {
        var cycles: [[String: Any]] = []
        guard let first = await host.start() else { throw HarnessError(host.lastError ?? "start failed") }
        var session = first.session
        for _ in 0..<3 {
            let stopStart = Date()
            await host.stop()
            let stopMs = Date().timeIntervalSince(stopStart) * 1000
            let stoppedState = host.node.map { "\($0.status().state)" } ?? "none"
            let startStart = Date()
            guard let next = await host.start() else { throw HarnessError(host.lastError ?? "restart failed") }
            cycles.append([
                "stop_ms": stopMs,
                "state_after_stop": stoppedState,
                "start_ms": Date().timeIntervalSince(startStart) * 1000,
                "previous_session": session,
                "session": next.session,
                "fresh_session": next.session > session,
                "same_port": next.wsPort == first.wsPort,
            ])
            session = next.session
        }
        return ["cycles": cycles]
    }

    static func bridge(host: NodeHost) async throws -> [String: Any] {
        BridgeReports.shared.latest = nil
        host.selectedTab = .bridge
        let deadline = Date().addingTimeInterval(60)
        while BridgeReports.shared.latest == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let report = BridgeReports.shared.latest else { throw HarnessError("the bridge page sent no report") }
        return report
    }

    static func traffic() -> [String: UInt64] {
        let now = nodeTraffic()
        return ["upload_bytes": now.uploadBytes, "download_bytes": now.downloadBytes]
    }

    static func trafficSince(_ before: [String: UInt64]) -> [String: UInt64] {
        traffic().reduce(into: [:]) { out, entry in
            out[entry.key] = entry.value &- (before[entry.key] ?? 0)
        }
    }

    /// Record peer counts and traffic for `appkit.watchSeconds` (default 60):
    /// idle traffic, and the reconnect when the harness changes the network.
    static func watch(host: NodeHost) async -> [String: Any] {
        let configured = UserDefaults.standard.integer(forKey: "appkit.watchSeconds")
        let duration = configured > 0 ? configured : 60
        _ = await host.start()
        _ = await host.waitForPeers(timeoutMs: 60_000)
        let before = traffic()
        let origin = ProcessClock.nowMs()
        var samples: [[String: Any]] = []
        for _ in 0..<duration {
            let status = host.node?.status()
            let now = traffic()
            samples.append([
                "ms": ProcessClock.nowMs() - origin,
                "peers": status?.connectedPeers ?? 0,
                "state": status.map { "\($0.state)" } ?? "none",
                "upload_bytes": now["upload_bytes"]! &- before["upload_bytes"]!,
                "download_bytes": now["download_bytes"]! &- before["download_bytes"]!,
            ])
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return ["seconds": duration, "samples": samples, "traffic": trafficSince(before)]
    }

    /// One second of the node's state, traffic and network path.
    static func sample(host: NodeHost, origin: Double, before: [String: UInt64], phase: String) -> [String: Any] {
        let status = host.node?.status()
        let now = traffic()
        return [
            "ms": ProcessClock.nowMs() - origin,
            "phase": phase,
            "path": NetworkPath.shared.kind,
            "peers": status?.connectedPeers ?? 0,
            "state": status.map { "\($0.state)" } ?? "none",
            "upload_bytes": now["upload_bytes"]! &- before["upload_bytes"]!,
            "download_bytes": now["download_bytes"]! &- before["download_bytes"]!,
        ]
    }

    /// Wait until the phone's network path is one of `kinds`, sampling every second.
    static func waitForPath(_ kinds: Set<String>, host: NodeHost, origin: Double, before: [String: UInt64],
                            phase: String, samples: inout [[String: Any]], timeout: Int = 180) async -> Bool {
        var matches = 0
        for _ in 0..<timeout {
            // Two readings in a row, so a path that is still settling does not count.
            matches = kinds.contains(NetworkPath.shared.kind) ? matches + 1 : 0
            if matches >= 2 { return true }
            samples.append(sample(host: host, origin: origin, before: before, phase: phase))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Wi-Fi to cellular and back, guided on screen: the person turns Wi-Fi off
    /// in Control Center, then on again. Records peers, traffic and path.
    static func transition(host: NodeHost) async throws -> [String: Any] {
        _ = await host.start()
        _ = await host.waitForPeers(timeoutMs: 60_000)
        let before = traffic()
        let origin = ProcessClock.nowMs()
        var samples: [[String: Any]] = []
        var marks: [[String: Any]] = []
        func mark(_ event: String) { marks.append(["event": event, "ms": ProcessClock.nowMs() - origin]) }
        for _ in 0..<15 {
            samples.append(sample(host: host, origin: origin, before: before, phase: "wifi"))
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        host.harnessPrompt = "Open Control Center and turn Wi-Fi OFF.\nKeep cellular data on."
        mark("prompt_wifi_off")
        guard await waitForPath(["cellular"], host: host, origin: origin, before: before, phase: "waiting_for_cellular", samples: &samples)
        else { host.harnessPrompt = nil; throw HarnessError("the phone never moved to cellular") }
        mark("on_cellular")
        host.harnessPrompt = "On cellular. Keep Wi-Fi off for one minute."
        for _ in 0..<60 {
            samples.append(sample(host: host, origin: origin, before: before, phase: "cellular"))
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        host.harnessPrompt = "Now turn Wi-Fi back ON in Control Center."
        mark("prompt_wifi_on")
        _ = await waitForPath(["wifi"], host: host, origin: origin, before: before, phase: "waiting_for_wifi", samples: &samples)
        mark("on_wifi")
        host.harnessPrompt = "Back on Wi-Fi. Thank you, measuring for 30 seconds."
        for _ in 0..<30 {
            samples.append(sample(host: host, origin: origin, before: before, phase: "wifi_again"))
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        host.harnessPrompt = nil
        return ["marks": marks, "samples": samples, "traffic": trafficSince(before), "path": NetworkPath.shared.summary]
    }

    /// Start the node with no network, guided on screen: the person turns on
    /// Airplane Mode, the node is stopped and started again, then the person
    /// turns Airplane Mode off and the node is started again if it failed.
    static func offlineStart(host: NodeHost) async throws -> [String: Any] {
        _ = await host.start()
        let before = traffic()
        let origin = ProcessClock.nowMs()
        var samples: [[String: Any]] = []
        var result: [String: Any] = [:]
        host.harnessPrompt = "Turn on Airplane Mode (Wi-Fi and cellular off)."
        guard await waitForPath(["none"], host: host, origin: origin, before: before, phase: "waiting_for_offline", samples: &samples)
        else { host.harnessPrompt = nil; throw HarnessError("the phone never went offline") }
        host.harnessPrompt = "Offline. Starting the node, please wait."
        await host.stop()
        let started = Date()
        let offlineInfo = await host.start()
        result["offline_start_ms"] = Date().timeIntervalSince(started) * 1000
        result["offline_start_ok"] = offlineInfo != nil
        result["offline_start_error"] = host.lastError as Any
        if offlineInfo != nil {
            // Cached River should still show with no network.
            let river = await webApp(.river, host: host, sampleSeconds: 0)
            result["offline_river_loaded"] = river["loaded"] as Any
        }
        host.harnessPrompt = "Now turn Airplane Mode OFF."
        _ = await waitForPath(["wifi", "cellular", "wired"], host: host, origin: origin, before: before, phase: "waiting_for_online", samples: &samples)
        let online = Date()
        host.harnessPrompt = "Online again. Measuring, please wait."
        if host.info == nil { _ = await host.start() }
        let peers = await host.waitForPeers(timeoutMs: 60_000)
        result["online_first_peer_ms"] = peers ? Date().timeIntervalSince(online) * 1000 : NSNull()
        result["online_start_error"] = host.info == nil ? (host.lastError as Any) : NSNull()
        host.harnessPrompt = nil
        result["samples"] = samples
        result["traffic"] = trafficSince(before)
        return result
    }

    /// A fresh node start on cellular, guided on screen: does the node join
    /// the network through the carrier's NAT?
    static func cellularStart(host: NodeHost) async throws -> [String: Any] {
        _ = await host.start()
        let before = traffic()
        let origin = ProcessClock.nowMs()
        var samples: [[String: Any]] = []
        var result: [String: Any] = [:]
        host.harnessPrompt = "Turn Wi-Fi OFF in Control Center.\nKeep cellular data on."
        guard await waitForPath(["cellular"], host: host, origin: origin, before: before, phase: "waiting_for_cellular", samples: &samples)
        else { host.harnessPrompt = nil; throw HarnessError("the phone never moved to cellular") }
        host.harnessPrompt = "On cellular. Restarting the node, please wait."
        await host.stop()
        let cellularBefore = traffic()
        let started = Date()
        let info = await host.start()
        result["cellular_start_ok"] = info != nil
        result["cellular_start_ms"] = Date().timeIntervalSince(started) * 1000
        result["cellular_start_error"] = info == nil ? (host.lastError as Any) : NSNull()
        let peers = info != nil ? await host.waitForPeers(timeoutMs: 60_000) : false
        result["cellular_first_peer_ms"] = peers ? Date().timeIntervalSince(started) * 1000 : NSNull()
        for _ in 0..<30 {
            samples.append(sample(host: host, origin: origin, before: before, phase: "cellular"))
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        result["cellular_traffic"] = trafficSince(cellularBefore)
        result["cellular_path"] = NetworkPath.shared.summary
        host.harnessPrompt = "Done. Turn Wi-Fi back ON."
        _ = await waitForPath(["wifi"], host: host, origin: origin, before: before, phase: "waiting_for_wifi", samples: &samples)
        host.harnessPrompt = nil
        result["samples"] = samples
        return result
    }

    /// Open River, then wait while the harness sends the app to the
    /// background and back, and time the return: fresh session, River again.
    static func resume(host: NodeHost) async throws -> [String: Any] {
        let first = await webApp(.river, host: host, sampleSeconds: 0)
        let log = host.lifecycleLog.count
        let deadline = Date().addingTimeInterval(180)
        var backgrounded: Double?
        var resumedAt: Double?
        while Date() < deadline {
            let entries = host.lifecycleLog.dropFirst(log)
            if backgrounded == nil, entries.contains(where: { $0.hasSuffix("backgrounding") }) {
                backgrounded = ProcessClock.nowMs()
            }
            if backgrounded != nil, entries.contains(where: { $0.hasSuffix("resumed with a fresh session") }) {
                resumedAt = ProcessClock.nowMs()
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let resumedAt else { throw HarnessError("the app was not backgrounded and resumed within 180 s") }
        // River reloads for the new session; wait for a title set after the
        // resume, not the one from before it.
        let timeline = WebTimeline.shared
        func reloaded() -> Bool {
            (timeline.marks[DemoWebApp.river.name] ?? []).contains { $0.event == "title:River" && $0.ms > resumedAt }
        }
        while Date() < deadline, !reloaded() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let marks = (timeline.marks[DemoWebApp.river.name] ?? []).filter { $0.ms >= resumedAt - 5_000 }
        return [
            "first_load": first,
            "backgrounded_at_ms": backgrounded as Any,
            "resumed_at_ms": resumedAt,
            "after_resume": marks.map { ["event": $0.event, "ms": $0.ms - resumedAt] },
            "session": host.info?.session as Any,
        ]
    }

    /// Subscription throughput: one connection subscribes, another sends
    /// `count` updates back to back, and the listener counts arrivals.
    static func throughput(count: Int = 200) async throws -> [String: Any] {
        try await FixtureNode.run { info in
            let reader = try await connectClient(wsPort: info.wsPort)
            let writer = try await connectClient(wsPort: info.wsPort)
            let put = try await reader.put(code: fixtureContractWasm(), parameters: Data([0x7A]),
                                           state: Data([1]), subscribe: false, timeoutMs: nil)
            let recorder = CountingListener()
            _ = try await reader.subscribe(instanceId: put.contract.instanceId, listener: recorder, timeoutMs: nil)
            let delta = Data(repeating: 0x42, count: 64)
            let started = Date()
            for _ in 0..<count {
                _ = try await writer.update(contract: put.contract, delta: delta, timeoutMs: 30_000)
            }
            let sent = Date().timeIntervalSince(started)
            let deadline = Date().addingTimeInterval(60)
            while recorder.count < count && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let received = Date().timeIntervalSince(started)
            let got = recorder.count
            var result: [String: Any] = [
                "updates": count, "delta_bytes": 64, "received": got,
                "send_seconds": sent, "receive_seconds": received,
                "updates_per_second": Double(got) / received,
                "final_state_bytes": 1 + count * 64,
                "notification_bytes": recorder.totalBytes,
            ]
            if got < count { result["error"] = "received \(got) of \(count) updates" }
            return result
        }
    }

    /// Message alerts: the shell page raises a notification the way the
    /// shell does for River, the host shows its banner, and a tap reaches the
    /// page's click handler.
    static func alerts(host: NodeHost) async throws -> [String: Any] {
        host.alertGrant = .granted
        let loaded = await webApp(.river, host: host, sampleSeconds: 0)
        guard let webView = WebViews.byApp[DemoWebApp.river.name] else { throw HarnessError("no River web view") }
        host.alert = nil
        let raised = ProcessClock.nowMs()
        _ = try? await webView.evaluateJavaScript("""
            (function () {
              var n = new Notification('Bob', { body: 'Skate club: see you at 6?', tag: 'skate-club' });
              n.onclick = function () { window.__appkitProbeClicked = true; };
              return true;
            })()
            """)
        let deadline = Date().addingTimeInterval(10)
        while host.alert == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let alert = host.alert else { throw HarnessError("no banner appeared") }
        let shown = ProcessClock.nowMs()
        host.openAlert(alert)
        try await Task.sleep(nanoseconds: 300_000_000)
        let clicked = (try? await webView.evaluateJavaScript("window.__appkitProbeClicked === true")) as? Bool ?? false
        return [
            "river_loaded": loaded["loaded"] as Any,
            "banner_title": alert.title, "banner_body": alert.body,
            "raise_to_banner_ms": shown - raised,
            "opened": clicked,
            "foreground_only": true,
        ]
    }

    /// Store contracts until the device refuses or 300 are stored, and record
    /// the address space each one reserves.
    static func wasmInstances() async throws -> [String: Any] {
        try await FixtureNode.run { info in
            let client = try await connectClient(wsPort: info.wsPort)
            let wasm = fixtureContractWasm()
            let start = processMetrics().virtualBytes
            var samples: [[String: Any]] = []
            var failure: String?
            var stored = 0
            for i in 0..<300 {
                do {
                    var params = Data(count: 2)
                    params[0] = UInt8(i & 0xFF); params[1] = UInt8(i >> 8)
                    _ = try await client.put(code: wasm, parameters: params, state: Data([1, 2, 3]),
                                             subscribe: false, timeoutMs: 30_000)
                    stored = i + 1
                } catch {
                    failure = "\(error)"
                    break
                }
                if stored % 25 == 0 {
                    let m = processMetrics()
                    samples.append(["contracts": stored, "virtual_bytes": m.virtualBytes,
                                    "footprint_bytes": m.footprintBytes as Any])
                }
            }
            let end = processMetrics().virtualBytes
            var result: [String: Any] = [
                "stored": stored, "samples": samples,
                "virtual_bytes_per_contract": stored > 0 ? Double(end &- start) / Double(stored) : 0,
            ]
            if let failure { result["error"] = failure }
            return result
        }
    }

    /// Load a web app and time each step, then sample memory.
    static func webApp(_ app: DemoWebApp, host: NodeHost, sampleSeconds: Int = 20) async -> [String: Any] {
        let before = traffic()
        host.selectedTab = app.tab
        let timeline = WebTimeline.shared
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if timeline.first(app, prefix: "title:\(app.name)") != nil && timeline.first(app, prefix: "app_frame_dom") != nil { break }
            if timeline.first(app, prefix: "load_failed") != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let marks = timeline.marks[app.name] ?? []
        let origin = marks.first?.ms ?? ProcessClock.nowMs()
        let loadTraffic = trafficSince(before)
        var samples: [Any] = []
        for _ in 0..<sampleSeconds {
            samples.append(json(processMetricsJson(metrics: processMetrics())))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return [
            "timeline": marks.map { ["event": $0.event, "ms": $0.ms - origin] },
            "loaded": timeline.first(app, prefix: "title:\(app.name)") != nil,
            "load_traffic": loadTraffic,
            "session_traffic": trafficSince(before),
            "memory_samples": samples,
            "status": host.node.map { json(nodeStatusJson(status: $0.status())) } as Any,
        ]
    }

    static func storage(host: NodeHost) -> [String: Any] {
        let dirs = host.directories
        return [
            "data_bytes": directorySizeBytes(path: dirs.data.path),
            "config_bytes": directorySizeBytes(path: dirs.config.path),
            "logs_bytes": directorySizeBytes(path: dirs.logs.path),
            "cache_bytes": directorySizeBytes(path: dirs.cache.path),
        ]
    }

    // MARK: Output

    static func expectedFixtureValues() throws -> [String: String] {
        let text = try AppResources.protocolFixtures
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return object?["values"] as? [String: String] ?? [:]
    }

    static func write(_ scenario: String, _ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
            print("APPKIT_RESULT {\"scenario\":\"\(scenario)\",\"error\":\"unserializable result\"}")
            return
        }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("appkit-results", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(scenario).json"))
        print("APPKIT_RESULT " + String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    static func deviceInfo() -> [String: Any] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let env = ProcessInfo.processInfo.environment
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return [
            "model": env["SIMULATOR_MODEL_IDENTIFIER"] ?? machine,
            "name": UIDevice.current.name,
            "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "simulator": simulator,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "cpu_count": ProcessInfo.processInfo.activeProcessorCount,
        ]
    }

    static func json(_ text: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? text
    }

    static func encode<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value) else { return NSNull() }
        return (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
    }
}

struct HarnessError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
