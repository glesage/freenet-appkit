import Darwin
import Foundation

/// Process-level timestamps for startup measurements, in milliseconds since
/// the Unix epoch.
enum ProcessClock {
    private(set) static var appInitMs: Double?
    private(set) static var firstFrameMs: Double?

    /// When the kernel started this process.
    static let processStartMs: Double? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
    }()

    static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    static func markAppInit() {
        if appInitMs == nil { appInitMs = nowMs() }
    }

    static func markFirstFrame() {
        if firstFrameMs == nil { firstFrameMs = nowMs() }
    }

    /// Milliseconds from process start to `ms`.
    static func sinceProcessStart(_ ms: Double?) -> Double? {
        guard let ms, let start = processStartMs else { return nil }
        return ms - start
    }
}
