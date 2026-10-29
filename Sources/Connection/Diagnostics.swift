import Foundation

/// 轻量真机诊断：统计流式帧/应用次数与主线程 stall（每 2s 一条固定格式 NSLog）。
///
/// 日志格式：`[DSHDiag] frames=… applied=… lastFlushMs=… mainStallMaxMs=…`
/// 主线程 stall 用后台 100ms 定时 ping 主队列，记录 >300ms 的最大延迟与次数。
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    private let lock = NSLock()
    private var frames = 0
    private var applied = 0
    private var lastFlushMs = 0.0
    private var maxStallMs = 0.0
    private var stallCount = 0
    private var logTimer: DispatchSourceTimer?
    private var stallTimer: DispatchSourceTimer?
    private var started = false

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        let logQueue = DispatchQueue(label: "dev.dsh.diag.log", qos: .utility)
        let logTimer = DispatchSource.makeTimerSource(queue: logQueue)
        logTimer.schedule(deadline: .now() + 2, repeating: 2)
        logTimer.setEventHandler { [weak self] in self?.logWindow() }
        logTimer.resume()
        self.logTimer = logTimer

        // 后台每 100ms ping 一次主队列，超过 300ms 记一次 stall。
        let stallQueue = DispatchQueue(label: "dev.dsh.diag.stall", qos: .utility)
        let stallTimer = DispatchSource.makeTimerSource(queue: stallQueue)
        stallTimer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        stallTimer.setEventHandler { [weak self] in
            let sent = Date()
            let record: @Sendable (Double) -> Void = { [weak self] latencyMs in
                self?.recordMainLatency(latencyMs)
            }
            DispatchQueue.main.async {
                record(Date().timeIntervalSince(sent) * 1000)
            }
        }
        stallTimer.resume()
        self.stallTimer = stallTimer
    }

    func recordFrame() {
        lock.lock(); frames += 1; lock.unlock()
    }

    func recordApplied() {
        lock.lock(); applied += 1; lock.unlock()
    }

    func recordFlushDuration(ms: Double) {
        lock.lock(); lastFlushMs = ms; lock.unlock()
    }

    private func recordMainLatency(_ ms: Double) {
        lock.lock()
        if ms > maxStallMs { maxStallMs = ms }
        if ms > 300 { stallCount += 1 }
        lock.unlock()
    }

    private func logWindow() {
        lock.lock()
        let f = frames, a = applied, flush = lastFlushMs, stall = maxStallMs
        frames = 0
        applied = 0
        maxStallMs = 0
        let stalls = stallCount
        stallCount = 0
        lock.unlock()
        NSLog("[DSHDiag] frames=%d applied=%d lastFlushMs=%.1f mainStallMaxMs=%.0f stalls=%d",
              f, a, flush, stall, stalls)
    }
}
