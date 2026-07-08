import SwiftUI

/// A clean, translucent on-video diagnostics panel. Refreshes once a second via `TimelineView` (off the
/// render path), pulling a fresh `PlaybackStats` snapshot from the model, and shows a live compute graphic
/// (CPU / GPU / Neural-Engine / memory) at the top. Section-based so new stat groups slot in without
/// changing this view.
///
/// The compute graphic is instrumented only while this overlay exists: `ComputeMonitor.start()` on appear
/// arms the sampler + the GPU probe, `.stop()` on disappear disarms them — so there's no cost when the
/// Stats window is closed.
struct StatsOverlayView: View {
    let scene: StashScene
    let model: ScenePlayerModel
    /// The direct file URL (unused now the demux/loopback self-tests are gone; kept so callers don't change).
    var probeURL: URL?
    /// Landscape fullscreen → a wider box (more fits per row); portrait → a taller box.
    var isLandscape = false
    @State private var debugLogging = RemoteLog.isLoggingEnabled
    @State private var compute = ComputeMonitor()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            panel(model.snapshotStats(scene: scene))
        }
        .onAppear {
            model.setStatsSampling(true)   // arm the engine's presented-frame counter
            compute.start(frameSource: {
                FrameHealthSample(presented: model.presentedFrameCount,
                                  dropped: model.droppedFrameCount,
                                  sourceFPS: scene.sourceFrameRate ?? 0,
                                  rate: model.playbackRate,
                                  playing: model.isPlaying)
            })
        }
        .onDisappear {
            compute.stop()
            model.setStatsSampling(false)
        }
    }

    private func panel(_ stats: PlaybackStats) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                // Live hardware graphic — proves which compute blocks are working (decode / GPU render /
                // AI Neural-Engine interpolation / transcode) and how hard.
                ComputeMetersView(monitor: compute, model: model)

                ForEach(stats.sections) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                        ForEach(section.lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.label)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 88, alignment: .leading)
                                Text(line.value)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                    }
                }
                }
                // Flatten the meters + stat rows into ONE rasterized layer. Un-flattened, this panel is
                // dozens of translucent text/bar layers composited OVER the video every display frame —
                // which knocks the compositor off the cheap direct-video path and reads as an fps drop the
                // moment the debug menu opens. Rasterizing costs one redraw per 1 Hz data tick instead.
                // (The Toggle stays outside — interactive controls don't rasterize well.)
                .drawingGroup()

                // Debug log streaming to ntfy (off by default — broadcasts to a public topic).
                Toggle(isOn: $debugLogging) {
                    Text("DEBUG LOG → ntfy/\(RemoteLog.topic)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .tint(.white.opacity(0.6))
                .onChange(of: debugLogging) { _, on in
                    RemoteLog.isLoggingEnabled = on
                    if on { RemoteLog.shared.enable() } else { RemoteLog.shared.disable() }
                }
            }
            .padding(12)
        }
        .frame(width: isLandscape ? 360 : 280)
        .frame(maxHeight: isLandscape ? 230 : 420)
        .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        // No drop shadow: over video it was invisible anyway, and shadowing a translucent panel forces an
        // offscreen pass composited at video frame rate — part of the debug-menu fps drop.
    }
}

// MARK: - Compute graphic

/// The hardware-usage graphic: a labelled bar meter (+ rolling sparkline) per compute block, so it's
/// obvious at a glance what's doing the work — CPU, the GPU (Metal blur + AI slow-mo compositing), the
/// Neural Engine (AI frame interpolation), and memory — plus a one-line summary of the active decode/
/// transcode pipeline.
private struct ComputeMetersView: View {
    let monitor: ComputeMonitor
    let model: ScenePlayerModel

    var body: some View {
        let sm = model.slowMoStats
        // Neural-Engine (ANE) load proxy: iOS exposes no ANE-utilisation API, so use the per-pair
        // interpolation time against a ~20 ms budget as the "how hard is it working" bar.
        let aneActive = model.slowMoActive && sm.active
        let aneFraction = aneActive ? min(1, sm.lastMs / 20) : 0

        VStack(alignment: .leading, spacing: 6) {
            Text("COMPUTE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))

            // Game-style UI fps: the link requests 120 Hz while this panel is open, so any lower reading
            // is real main-thread hitching; "worst" is the single longest frame in the last second.
            MeterRow(label: "UI", fraction: min(1, monitor.uiFPS / 120),
                     value: "\(Int(monitor.uiFPS)) fps",
                     detail: monitor.worstFrameMs > 0 ? String(format: "worst %.0f ms", monitor.worstFrameMs) : nil,
                     history: monitor.uiHistory,
                     tint: monitor.uiFPS >= 110 ? .green : (monitor.uiFPS >= 80 ? .yellow : .red))

            MeterRow(label: "CPU", fraction: monitor.cpuFraction,
                     value: "\(Int(monitor.cpuPercent))%", history: monitor.cpuHistory, tint: .orange)

            MeterRow(label: "GPU", fraction: monitor.gpuFraction,
                     value: "\(Int(monitor.gpuFraction * 100))%",
                     detail: monitor.gpuFPS >= 1 ? "Metal · \(Int(monitor.gpuFPS)) fps" : "idle",
                     history: monitor.gpuHistory, tint: .green)

            MeterRow(label: "NPU", fraction: aneFraction,
                     value: aneActive ? String(format: "%.0fms", sm.lastMs) : "—",
                     detail: aneActive ? "AI slow-mo · \(sm.synthesized) synth"
                           : (model.aiSlowMoEnabled ? "AI slow-mo idle" : "AI slow-mo off"),
                     tint: .purple)

            MeterRow(label: "MEM", fraction: min(1, monitor.memoryMB / 2000),
                     value: "\(Int(monitor.memoryMB)) MB", tint: .blue)

            // Decode health — is the hardware decoder keeping up with the file's frame rate (green),
            // slipping (amber), or falling behind (red)? Judged against sourceFPS × current playback rate,
            // so slow-mo doesn't read as a fault; grey while paused.
            MeterRow(label: "DEC",
                     fraction: monitor.expectedFPS > 0 ? min(1, monitor.decodeFPS / monitor.expectedFPS) : 0,
                     value: monitor.framePlaying ? "\(Int(monitor.decodeFPS)) fps" : "—",
                     detail: monitor.framePlaying ? "target \(Int(monitor.expectedFPS)) fps" : "paused",
                     history: monitor.decodeHistory, tint: decodeColor)

            // Dropped frames per second — a few at start/seek is normal (green); a steady climb means the
            // phone is compute-bound (amber → red), the cue to drop resolution or disable AI slow-mo.
            MeterRow(label: "DROP",
                     fraction: min(1, monitor.droppedPerSec / 10),
                     value: String(format: "%.0f/s", monitor.droppedPerSec),
                     detail: "total \(model.droppedFrameCount)",
                     history: monitor.dropHistory, tint: dropColor)

            // Active decode/transcode pipeline (what's actually turning bytes into frames right now).
            Text(pipelineSummary)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.bottom, 2)
    }

    /// Decode-health colour: green = keeping up (≥90% of target fps), amber = slipping (≥70%), red = behind.
    /// Grey while paused or when the source fps is unknown (nothing to judge against).
    private var decodeColor: Color {
        guard monitor.framePlaying, monitor.expectedFPS > 0.5 else { return .gray }
        let ratio = monitor.decodeFPS / monitor.expectedFPS
        return ratio >= 0.9 ? .green : (ratio >= 0.7 ? .yellow : .red)
    }

    /// Dropped-frames colour: green < 1/s, amber 1–5/s, red > 5/s (the phone is dropping to keep sync).
    private var dropColor: Color {
        let d = monitor.droppedPerSec
        return d < 1 ? .green : (d < 5 ? .yellow : .red)
    }

    /// One-line summary of the current pipeline: the cost tier + the fact decode is hardware VideoToolbox.
    private var pipelineSummary: String {
        let tier: String
        switch model.playbackTier {
        case .direct: tier = "Direct play"
        case .remux:  tier = "On-device remux"
        case .server: tier = "Server transcode"
        }
        let size = model.presentationSize
        let res = size.width > 0 ? " · \(Int(size.width))×\(Int(size.height))" : ""
        return "\(tier) · VideoToolbox HW decode\(res)"
    }
}

/// A single compute meter: label, a proportional bar, an optional rolling sparkline of recent history, and
/// a right-aligned readout, with an optional sub-caption.
private struct MeterRow: View {
    let label: String
    let fraction: Double        // 0…1 for the bar
    let value: String
    var detail: String? = nil
    var history: [Double]? = nil
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 30, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(tint.opacity(0.9))
                            .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                    }
                }
                .frame(height: 5)
                if let history {
                    Sparkline(values: history, color: tint)
                        .frame(width: 46, height: 12)
                }
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .trailing)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 36)
            }
        }
    }
}

/// A tiny line chart of recent normalised (0…1) samples, oldest→newest left→right.
private struct Sparkline: View {
    let values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard values.count > 1 else { return }
                let w = geo.size.width, h = geo.size.height
                let step = w / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * step
                    let y = h - CGFloat(min(1, max(0, v))) * h
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
