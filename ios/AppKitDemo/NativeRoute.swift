import FreenetAppKit
import Foundation

/// A local-mode node with its own store, apart from the app's network store,
/// for fixtures and measurements.
enum FixtureNode {
    static func run<T>(_ body: (NodeInfo) async throws -> T) async throws -> T {
        let dirs = try NodeDirectories.standard(folder: "freenet-fixtures")
        let node = try MobileNode(settings: dirs.settings(mode: .local))
        let info = try await node.start()
        do {
            let result = try await body(info)
            try await node.stop()
            return result
        } catch {
            try? await node.stop()
            throw error
        }
    }
}

/// Collects subscription callbacks in arrival order.
final class CallbackRecorder: ContractListener, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func onUpdate(contract: ContractRef, kind: UpdateKind, bytes: Data) {
        let name: String
        switch kind {
        case .state: name = "State"
        case .delta: name = "Delta"
        case .stateAndDelta: name = "StateAndDelta"
        case .related: name = "Related"
        }
        lock.withLock { events.append("\(name):\(bytes.hex)") }
    }

    func onClosed(reason: String) {
        lock.withLock { events.append("closed:\(reason)") }
    }

    var snapshot: [String] { lock.withLock { events } }
}

/// Counts subscription callbacks and does nothing else on the callback
/// thread, which is one of the node runtime's workers.
final class CountingListener: ContractListener, @unchecked Sendable {
    private let lock = NSLock()
    private var updates = 0
    private var bytes = 0

    func onUpdate(contract: ContractRef, kind: UpdateKind, bytes data: Data) {
        lock.withLock { updates += 1; bytes += data.count }
    }

    func onClosed(reason: String) {}

    var count: Int { lock.withLock { updates } }
    var totalBytes: Int { lock.withLock { bytes } }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The custom Swift route: the same scripted operations as the Rust
/// fixtures, called through the Swift bindings, then compared with the
/// desktop values.
enum NativeRoute {
    struct Check: Codable {
        let name: String
        let expected: String?
        let actual: String
        let passed: Bool
    }

    static func kindName(_ error: Error) -> String {
        if let mobile = error as? MobileError {
            switch mobile {
            case .Client(let kind, _): return clientErrorKindName(kind: kind)
            case .Timeout: return "Timeout"
            default: return "error:\(mobile)"
            }
        }
        return "error:\(error)"
    }

    /// Run the operations and compare them with `expected` (the desktop file).
    static func run(expected: [String: String]) async throws -> [Check] {
        try await FixtureNode.run { info in
            let client = try await connectClient(wsPort: info.wsPort)
            let writer = try await connectClient(wsPort: info.wsPort)
            var actual: [String: String] = [:]
            let wasm = fixtureContractWasm()

            let put = try await client.put(code: wasm, parameters: Data(), state: Data([1, 2, 3]), subscribe: false, timeoutMs: nil)
            actual["op.put.instance_id"] = put.contract.instanceId
            actual["op.put.code_hash"] = put.contract.codeHash
            let first = try await client.get(instanceId: put.contract.instanceId, returnCode: false, subscribe: false, timeoutMs: nil)
            actual["op.get.state"] = first.state.hex
            let updated = try await client.update(contract: put.contract, delta: Data([4, 5]), timeoutMs: nil)
            actual["op.update.summary"] = updated.summary.hex
            let second = try await client.get(instanceId: put.contract.instanceId, returnCode: false, subscribe: false, timeoutMs: nil)
            actual["op.get_after_update.state"] = second.state.hex

            let recorder = CallbackRecorder()
            _ = try await client.subscribe(instanceId: put.contract.instanceId, listener: recorder, timeoutMs: nil)
            for delta in [6, 7, 8] as [UInt8] {
                _ = try await writer.update(contract: put.contract, delta: Data([delta]), timeoutMs: nil)
            }
            let deadline = Date().addingTimeInterval(10)
            while recorder.snapshot.count < 3 && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            actual["op.subscribe.callbacks"] = recorder.snapshot.prefix(3).joined(separator: ",")

            do {
                let unknown = expected["key.instance_id"] ?? put.contract.instanceId
                _ = try await client.get(instanceId: unknown, returnCode: false, subscribe: false, timeoutMs: 10_000)
                actual["op.error.get_unknown"] = "ok"
            } catch {
                actual["op.error.get_unknown"] = kindName(error)
            }
            do {
                _ = try await client.put(code: wasm, parameters: Data([9]), state: Data(), subscribe: false, timeoutMs: nil)
                actual["op.error.put_invalid_state"] = "ok"
            } catch {
                actual["op.error.put_invalid_state"] = kindName(error)
            }
            do {
                _ = try await client.put(code: wasm, parameters: Data([7]), state: Data([0xF3]), subscribe: false, timeoutMs: 500)
                actual["op.cancel.timed_out"] = "ok"
            } catch {
                actual["op.cancel.timed_out"] = kindName(error)
            }
            let after = try await client.get(instanceId: put.contract.instanceId, returnCode: false, subscribe: false, timeoutMs: nil)
            actual["op.cancel.read_after"] = after.state.hex

            return actual.keys.sorted().map { name in
                let value = actual[name]!
                let want = expected[name]
                return Check(name: name, expected: want, actual: value, passed: want == value)
            }
        }
    }

    struct CopySample: Codable {
        let bytes: Int
        /// Swift to Rust and back with no node work.
        let echoMs: Double
        /// Put: Swift wall time, and the node's share measured in Rust.
        let putMs: Double
        let putNodeMs: Double
        /// Get: Swift wall time, and the node's share measured in Rust.
        let getMs: Double
        let getNodeMs: Double
        let intact: Bool
    }

    /// Large-record copying: time each size through the bindings alone and
    /// through a real put and get, and split the cost by layer.
    static func largeRecords(sizes: [Int]) async throws -> [CopySample] {
        try await FixtureNode.run { info in
            let client = try await connectClient(wsPort: info.wsPort)
            let wasm = fixtureContractWasm()
            var samples: [CopySample] = []
            for (index, size) in sizes.enumerated() {
                var bytes = Data(count: size)
                bytes.withUnsafeMutableBytes { raw in
                    let buf = raw.bindMemory(to: UInt8.self)
                    for i in stride(from: 0, to: buf.count, by: 4096) { buf[i] = UInt8(truncatingIfNeeded: i >> 12) }
                    buf[0] = 0x01
                }
                let echoStart = Date()
                let echoed = echoBytes(bytes: bytes)
                let echoMs = Date().timeIntervalSince(echoStart) * 1000

                // Distinct parameters give each size its own contract.
                let params = Data([UInt8(index + 1)])
                let putStart = Date()
                let put = try await client.put(code: wasm, parameters: params, state: bytes, subscribe: false, timeoutMs: 120_000)
                let putMs = Date().timeIntervalSince(putStart) * 1000
                let getStart = Date()
                let got = try await client.get(instanceId: put.contract.instanceId, returnCode: false, subscribe: false, timeoutMs: 120_000)
                let getMs = Date().timeIntervalSince(getStart) * 1000
                samples.append(CopySample(
                    bytes: size, echoMs: echoMs, putMs: putMs, putNodeMs: put.timing.nodeMs,
                    getMs: getMs, getNodeMs: got.timing.nodeMs,
                    intact: echoed == bytes && got.state == bytes))
            }
            return samples
        }
    }
}
