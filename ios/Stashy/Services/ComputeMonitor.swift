import SwiftUI
import Darwin
import QuartzCore

/// Gate for the GPU frame-time probe. Read on the render thread (Metal completion handlers) once per
/// drawn frame, so it's a bare `Bool` — flipped only when the Stats overlay opens or closes. When it's
/// `false` the renderers add **no** completion handler at all, so there is zero measurable cost with the
/// Stats window off (the whole point: the gauge instruments nothing until you look at it).
enum GPUProbe {
    nonisolated(unsafe) static var active = false
}

/// Thread-safe accumulator for GPU busy-time reported by the app's Metal renderers (the live blur backdrop
/// and the AI slow-mo compositor). Each drawn frame's `gpuEndTime − gpuStartTime` is added from the command
/// buffer's completion handler (a background thread); `ComputeMonitor` drains the running total once per
/// sample tick on the main actor and converts it to a busy fraction. `@unchecked Sendable` — a plain lock
/// guards the two counters.
final class GPUTimeAccumulator: @unchecked Sendable {
    static let shared = GPUTimeAccumulator()
    private let lock = NSLock()
    private var seconds = 0.0
    private var frames = 0

    /// Add one drawn frame's GPU execution time (seconds). Called off the main thread.
    func record(_ s: Double) {
        guard s.isFinite, s > 0 else { return }
        lock.withLock { seconds += s; frames += 1 }
    }

    /// Total GPU seconds + frame count since the last drain, then reset to zero.
    func drain() -> (seconds: Double, frames: Int) {
        lock.withLock { let r = (seconds, frames); seconds = 0; frames = 0; return r }
    }

    func reset() { lock.withLock { seconds = 0; frames = 0 } }
}

/// Live compute telemetry for the Stats overlay's hardware graphic: app CPU load, GPU busy-time from the
/// app's own Metal passes, and process memory — sampled at 2 Hz **only while the overlay is open**. `start()`
/// arms the GPU probe and the sampling loop; `stop()` disarms both, so nothing runs when the window is shut.
@MainActor
@Observable
final class ComputeMonitor {
    /// Whole-process CPU load across all cores (can exceed 100% — it's the sum of per-core usage).
    private(set) var cpuPercent = 0.0
    /// GPU busy fraction of wall-clock (0…1) from the app's Metal render passes (blur + AI slow-mo).
    private(set) var gpuFraction = 0.0
    /// GPU frames drawn per second in the last window (0 ⇒ the Metal compositor is idle).
    private(set) var gpuFPS = 0.0
    private(set) var memoryMB = 0.0
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSample = CACurrentMediaTime()
    private let historyCap = 40
    private let coreCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// Fraction 0…1 for the CPU bar — normalised so a full bar means every core is saturated.
    var cpuFraction: Double { min(1, cpuPercent / (coreCount * 100)) }

    func start() {
        guard task == nil else { return }
        GPUProbe.active = true
        GPUTimeAccumulator.shared.reset()
        lastSample = CACurrentMediaTime()
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.sample()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        GPUProbe.active = false
        GPUTimeAccumulator.shared.reset()
    }

    private func sample() {
        let now = CACurrentMediaTime()
        let elapsed = max(0.05, now - lastSample)
        lastSample = now

        cpuPercent = Self.appCPUPercent()
        memoryMB = RemoteLog.memoryMB()
        let g = GPUTimeAccumulator.shared.drain()
        gpuFraction = min(1, g.seconds / elapsed)
        gpuFPS = Double(g.frames) / elapsed

        push(&cpuHistory, cpuFraction)
        push(&gpuHistory, gpuFraction)
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyCap { arr.removeFirst(arr.count - historyCap) }
    }

    /// Total CPU usage (%) of this process, summed across all its non-idle threads. Values above 100 mean
    /// more than one core's worth of work (e.g. decode + blur + interpolation in parallel).
    static func appCPUPercent() -> Double {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: UnsafeRawPointer(list))),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            // TH_FLAGS_IDLE = 0x1, TH_USAGE_SCALE = 1000 (mach/thread_info.h) — hardcoded so the build
            // doesn't depend on those C macros being surfaced to Swift.
            if kr == KERN_SUCCESS, (info.flags & 0x1) == 0 {
                total += Double(info.cpu_usage) / 1000.0 * 100.0
            }
        }
        return total
    }
}
