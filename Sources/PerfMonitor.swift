import Foundation
import QuartzCore

/// Lightweight perf counters. Every 5s emits a summary line via Diag.log:
///
///   perf: 59.8 fps | CT 24.0hz avg 2.1ms | GPU avg 1.3ms max 3.8ms | dirty avg 1.8
///
/// Read with:
///   log show --predicate 'eventMessage CONTAINS "perf:"' --last 5m --info
///
/// Thread model: frameTick() and recordCT() are called from the main thread
/// (display link + TextEngine.update both run there). recordGPU() is called
/// from a Metal completion handler on an unspecified thread, so it dispatches
/// to main before mutating counters.
final class PerfMonitor {
    static let shared = PerfMonitor()

    private var frames = 0
    private var ctCount = 0
    private var ctTotalMs: Double = 0
    private var gpuCount = 0
    private var gpuTotalMs: Double = 0
    private var gpuMaxMs: Double = 0
    private var dirtyTotal = 0
    private var lastEmit: CFTimeInterval = 0

    private let emitInterval: CFTimeInterval = 5.0

    func frameTick() {
        frames += 1
        let now = CACurrentMediaTime()
        if lastEmit == 0 { lastEmit = now; return }
        if now - lastEmit >= emitInterval {
            emit(elapsed: now - lastEmit)
            lastEmit = now
        }
    }

    func recordCT(durationMs: Double, dirtyCount: Int) {
        ctCount += 1
        ctTotalMs += durationMs
        dirtyTotal += dirtyCount
    }

    /// Safe to call from any thread. Hops to main before mutating state.
    func recordGPU(durationMs: Double) {
        DispatchQueue.main.async {
            self.gpuCount += 1
            self.gpuTotalMs += durationMs
            if durationMs > self.gpuMaxMs { self.gpuMaxMs = durationMs }
        }
    }

    private func emit(elapsed: CFTimeInterval) {
        let fps = Double(frames) / elapsed
        let ctHz = Double(ctCount) / elapsed
        let ctAvgMs = ctCount > 0 ? ctTotalMs / Double(ctCount) : 0
        let gpuAvgMs = gpuCount > 0 ? gpuTotalMs / Double(gpuCount) : 0
        let dirtyAvg = ctCount > 0 ? Double(dirtyTotal) / Double(ctCount) : 0

        Diag.log(String(format: "perf: %.1f fps | CT %.1fhz avg %.1fms | GPU avg %.1fms max %.1fms | dirty avg %.1f",
                        fps, ctHz, ctAvgMs, gpuAvgMs, gpuMaxMs, dirtyAvg))

        frames = 0
        ctCount = 0; ctTotalMs = 0; dirtyTotal = 0
        gpuCount = 0; gpuTotalMs = 0; gpuMaxMs = 0
    }
}
