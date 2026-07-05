import CoreMedia
import CoreVideo
import VideoToolbox

/// Phase 1a of on-device AI slow-motion (see ROADMAP → "AI / motion-interpolated slow-mo"). A small,
/// self-contained wrapper over VideoToolbox's **low-latency frame interpolation** (`VTFrameProcessor`,
/// new in iOS 26, Neural-Engine accelerated on Apple silicon). It turns a pair of consecutive decoded
/// frames — `previous` → `current` — into N synthesised in-between frames, so slowed playback shows real
/// intermediate motion instead of the same frame held for several display refreshes (the judder you get
/// from plain `AVPlayer` rate < 1).
///
/// This class does *only* "two frames in → N synthesised frames out". The render loop that pulls frames
/// (from the existing `AVPlayerItemVideoOutput` tap), paces the synthesised stream onto a display layer,
/// and engages this at ≤0.5× is Phase 1b — deliberately separate so the risky new-API surface lands and
/// compiles on its own before it can touch the load-bearing playback path.
///
/// Concurrency: intentionally **non-isolated** and **`@unchecked Sendable`**. `interpolate(...)` builds its
/// VideoToolbox parameter objects and awaits `process` all within one isolation domain, so no non-`Sendable`
/// value crosses an actor boundary inside here. The `@unchecked` promise is upheld by the caller
/// (`SlowMoRunner`): it starts the session on the main actor *before* any work runs, then issues **one**
/// `interpolate` at a time (single-flight), so `started`/`pool` are never touched concurrently.
final class SlowMoInterpolator: @unchecked Sendable {
    /// Frame dimensions the session is configured for. A size change needs a fresh interpolator.
    let width: Int
    let height: Int
    /// Max synthesised frames per source pair (session config). Phase 1 uses 1 → 2× (one mid frame).
    let interpolatedFrames: Int

    private let processor = VTFrameProcessor()
    private var started = false
    private var pool: CVPixelBufferPool?

    init(width: Int, height: Int, interpolatedFrames: Int = 1) {
        self.width = width
        self.height = height
        self.interpolatedFrames = max(1, interpolatedFrames)
    }

    /// Start the VideoToolbox session (idempotent). Returns `false` if the effect isn't available on this
    /// device (non-Apple-silicon / unsupported) — the caller then falls back to plain slow playback.
    @discardableResult
    func startIfNeeded() -> Bool {
        if started { return true }
        guard let config = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: interpolatedFrames)
        else { return false }
        do {
            try processor.startSession(configuration: config)
            started = true
            return true
        } catch {
            return false
        }
    }

    /// Synthesise `phases.count` frames between `previous` and `current`. Phases are fractions in (0,1)
    /// from the previous frame (0) to the current one (1) — e.g. `[0.5]` for one mid frame, or
    /// `[0.25, 0.5, 0.75]` for 4×. Returns the synthesised buffers in phase order, or `[]` on any failure
    /// (so the caller can fall back to showing the real frames un-interpolated).
    func interpolate(previous: CVPixelBuffer, previousPTS: CMTime,
                     current: CVPixelBuffer, currentPTS: CMTime,
                     phases: [Double]) async -> [CVPixelBuffer] {
        guard started || startIfNeeded() else { return [] }
        // VTFrameProcessorFrame requires IOSurface-backed buffers; the tap's BGRA buffers are.
        guard let previousFrame = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousPTS),
              let currentFrame = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: currentPTS)
        else { return [] }

        let span = currentPTS - previousPTS
        var destinations: [CVPixelBuffer] = []
        var destinationFrames: [VTFrameProcessorFrame] = []
        for phase in phases {
            guard let buffer = makeDestinationBuffer() else { return [] }
            let pts = previousPTS + CMTimeMultiplyByFloat64(span, multiplier: phase)
            guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts) else { return [] }
            destinations.append(buffer)
            destinationFrames.append(frame)
        }

        guard let parameters = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: currentFrame,
            previousFrame: previousFrame,
            interpolationPhase: phases.map { Float($0) },
            destinationFrames: destinationFrames)
        else { return [] }

        // VideoToolbox fills the destination buffers in place on its own queue; we just await it.
        do {
            _ = try await processor.process(parameters: parameters)
        } catch {
            return []
        }
        return destinations
    }

    /// End the session and drop the pool.
    func invalidate() {
        if started { processor.endSession(); started = false }
        pool = nil
    }

    /// Lazily build an IOSurface-backed BGRA pixel-buffer pool for the synthesised (destination) frames,
    /// matching the format of the app's `AVPlayerItemVideoOutput` tap.
    private func makeDestinationBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
