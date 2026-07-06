import Accelerate
import CoreMedia
import CoreVideo
import VideoToolbox

/// On-device AI slow-motion frame interpolation over VideoToolbox's **low-latency frame interpolation**
/// (`VTFrameProcessor`, iOS 26, Neural-Engine accelerated). Turns a pair of consecutive decoded frames —
/// `previous` → `current` — into N synthesised in-between frames, so slowed playback shows real intermediate
/// motion instead of the same frame held for several refreshes (the judder from plain `AVPlayer` rate < 1).
///
/// **Resolution workaround (v1.0.197):** `VTLowLatencyFrameInterpolation` *hard-crashes* at 1280×720 on
/// iOS 26.x (reproduced across multiple HEVC + H.264 files; 1920×1080 works fine). So sub-1080p frames are
/// scaled up to a safe **1920×1080** interpolation size (via vImage) before being handed to VideoToolbox —
/// 720p content gets smooth slow-mo instead of crashing. Content already ≥1080p is interpolated natively.
///
/// Concurrency: intentionally **non-isolated** and **`@unchecked Sendable`**. `interpolate(...)` builds its
/// VideoToolbox parameter objects and awaits `process` all within one isolation domain, so no non-`Sendable`
/// value crosses an actor boundary here. The `@unchecked` promise is upheld by the caller (`SlowMoRunner`):
/// it issues **one** `interpolate` at a time (single-flight), so the session/pools are never touched
/// concurrently.
final class SlowMoInterpolator: @unchecked Sendable {
    /// The decoded source size handed in by the caller.
    let nativeWidth: Int
    let nativeHeight: Int
    /// The size interpolation actually runs at (native, or upscaled to dodge the 1280×720 crash).
    let width: Int
    let height: Int
    /// True when frames are scaled from native → interpolation size.
    let scaled: Bool
    /// Max synthesised frames per source pair (session config). Phase 1 uses 1 → 2× (one mid frame).
    let interpolatedFrames: Int

    private let processor = VTFrameProcessor()
    private var started = false
    private var config: VTLowLatencyFrameInterpolationConfiguration?   // retained for the session's lifetime
    private var sourcePool: CVPixelBufferPool?        // scaled source frames (interpolation size)
    private var destinationPool: CVPixelBufferPool?   // synthesised outputs (interpolation size)

    init(width: Int, height: Int, interpolatedFrames: Int = 1) {
        self.nativeWidth = width
        self.nativeHeight = height
        let safe = Self.safeInterpolationSize(width: width, height: height)
        self.width = safe.width
        self.height = safe.height
        self.scaled = (safe.width != width || safe.height != height)
        self.interpolatedFrames = max(1, interpolatedFrames)
    }

    /// The resolution to actually interpolate at. `VTLowLatencyFrameInterpolation` hard-crashes at 1280×720
    /// (and likely other sub-1080p sizes) on iOS 26.x but works at 1920×1080, so anything smaller than 1080p
    /// is bumped up to 1920×1080. (Content ≥1080p that the model can't handle throws — caught — rather than
    /// crashing, so it's left native.)
    static func safeInterpolationSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (width < 1920 || height < 1080) ? (1920, 1080) : (width, height)
    }

    /// Start the VideoToolbox session (idempotent). Returns `false` if the effect isn't available on this
    /// device (non-Apple-silicon / unsupported) — the caller then falls back to plain slow playback.
    @discardableResult
    func startIfNeeded() -> Bool {
        if started { return true }
        guard let cfg = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: interpolatedFrames)
        else { return false }
        do {
            try processor.startSession(configuration: cfg)
            config = cfg          // keep the configuration alive for the session's lifetime
            started = true
            return true
        } catch {
            return false
        }
    }

    /// Synthesise `phases.count` frames between `previous` and `current`. Phases are fractions in (0,1) from
    /// the previous frame (0) to the current one (1) — e.g. `[0.5]` for one mid frame. Returns the synthesised
    /// buffers (at the interpolation size) in phase order, or `[]` on any failure.
    func interpolate(previous: CVPixelBuffer, previousPTS: CMTime,
                     current: CVPixelBuffer, currentPTS: CMTime,
                     phases: [Double]) async -> [CVPixelBuffer] {
        guard started || startIfNeeded() else { logFail("no-session"); return [] }
        // Scale native frames up to the (crash-safe) interpolation size when needed.
        guard let previousSized = scaled ? scaleToInterpolationSize(previous) : previous,
              let currentSized  = scaled ? scaleToInterpolationSize(current)  : current
        else { logFail("scale-nil"); return [] }
        // VTFrameProcessorFrame requires IOSurface-backed buffers; the tap's (and our pool's) BGRA buffers are.
        guard let previousFrame = VTFrameProcessorFrame(buffer: previousSized, presentationTimeStamp: previousPTS),
              let currentFrame = VTFrameProcessorFrame(buffer: currentSized, presentationTimeStamp: currentPTS)
        else { logFail("frame-nil"); return [] }

        let span = currentPTS - previousPTS
        var destinations: [CVPixelBuffer] = []
        var destinationFrames: [VTFrameProcessorFrame] = []
        for phase in phases {
            guard let buffer = makeBuffer(&destinationPool) else { logFail("dest-buf-nil"); return [] }
            let pts = previousPTS + CMTimeMultiplyByFloat64(span, multiplier: phase)
            guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts) else { logFail("dest-frame-nil"); return [] }
            destinations.append(buffer)
            destinationFrames.append(frame)
        }

        guard let parameters = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: currentFrame,
            previousFrame: previousFrame,
            interpolationPhase: phases.map { Float($0) },
            destinationFrames: destinationFrames)
        else { logFail("params-nil"); return [] }

        // VideoToolbox fills the destination buffers in place on its own queue; we just await it.
        do {
            _ = try await processor.process(parameters: parameters)
        } catch {
            logFail("process:\(error)")
            return []
        }
        return destinations
    }

    /// Log the first interpolation failure point (once) off-device — pins down why `synthesized` stays 0
    /// (e.g. a `process` throw naming an unsupported pixel format).
    private var didLogFail = false
    private func logFail(_ reason: String) {
        guard !didLogFail else { return }
        didLogFail = true
        RemoteLog.shared.event("⚙︎ slowmo-fail", [
            ("where", reason),
            ("interp", "\(width)×\(height)"),
            ("native", "\(nativeWidth)×\(nativeHeight)")
        ])
    }

    /// End the session and drop the pools.
    func invalidate() {
        if started { processor.endSession(); started = false }
        config = nil
        sourcePool = nil
        destinationPool = nil
    }

    /// Scale a native decoded frame into an interpolation-size (`width`×`height`) BGRA buffer with vImage.
    /// A plain stretch — the app's content is 16:9 so 720p→1080p introduces no distortion; non-16:9 is only
    /// used for the (not-yet-rendered) telemetry pipeline today.
    private func scaleToInterpolationSize(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let destination = makeBuffer(&sourcePool) else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else { return nil }
        var src = vImage_Buffer(data: sourceBase,
                                height: vImagePixelCount(CVPixelBufferGetHeight(source)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(source)),
                                rowBytes: CVPixelBufferGetBytesPerRow(source))
        var dst = vImage_Buffer(data: destinationBase,
                                height: vImagePixelCount(height),
                                width: vImagePixelCount(width),
                                rowBytes: CVPixelBufferGetBytesPerRow(destination))
        return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            ? destination : nil
    }

    /// Lazily build an IOSurface-backed BGRA pixel-buffer pool at the interpolation size.
    private func makeBuffer(_ pool: inout CVPixelBufferPool?) -> CVPixelBuffer? {
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
