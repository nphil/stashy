import SwiftUI

/// Transient feedback on the GLASSES during playback — the other half of the eyes-free remote: every
/// phone gesture answers here, where the eyes are. Hosted above the video container, below the
/// blackout. White ≥0.92-never-pure on flat black-0.40 capsules (birdbath optics bloom pure white;
/// glass materials have nothing to refract over black). Opacity/transform-only at 60 Hz.
struct GlassesPlaybackOSD: View {
    @Bindable var coordinator: GlassesCoordinator

    var body: some View {
        ZStack {
            if let player = coordinator.player {
                pausedCard(player)
                skipBadge
                scrubStrip(player)
                speedPill(player)
                modeChips(player)
                volumePill(player)
                loadingHint(player)
            }
        }
        .animation(.easeOut(duration: 0.18), value: coordinator.player?.isPlaying ?? true)
        .animation(.easeOut(duration: 0.18), value: coordinator.scrubTarget != nil)
        .animation(.easeOut(duration: 0.18), value: coordinator.speedPulse)
        .animation(.easeOut(duration: 0.18), value: coordinator.volumePulse)
        .animation(.easeOut(duration: 0.18), value: coordinator.isZoomed)
    }

    // MARK: - Paused

    @ViewBuilder
    private func pausedCard(_ player: ScenePlayerModel) -> some View {
        if !player.isPlaying, player.isReady, coordinator.scrubTarget == nil {
            ZStack {
                Color.black.opacity(0.40).ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 88, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("\(Self.clock(player.currentTime)) / \(Self.clock(player.duration))")
                        .font(.system(size: 30, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Skip badge (±10 s accumulator)

    @ViewBuilder
    private var skipBadge: some View {
        if let skip = coordinator.skipBadge {
            HStack {
                if skip < 0 { badge(symbol: "gobackward.10", text: "\(skip)s") }
                Spacer()
                if skip > 0 { badge(symbol: "goforward.10", text: "+\(skip)s") }
            }
            .padding(.horizontal, 240)
            .transition(.opacity)
        }
    }

    private func badge(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 96, weight: .medium))
            Text(text)
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white.opacity(0.92))
        .shadow(color: .black.opacity(0.8), radius: 12)
    }

    // MARK: - Scrub strip (bottom third)

    @ViewBuilder
    private func scrubStrip(_ player: ScenePlayerModel) -> some View {
        if let target = coordinator.scrubTarget {
            VStack {
                Spacer()
                VStack(spacing: 20) {
                    // Sprite-sheet preview of the target frame (Netflix scrub model). Re-rendered per
                    // scrubTarget tick — `thumbnail(at:)` is a cached crop, cheap at 60 Hz. Sprites are
                    // upscaled from ~160pt tiles; soft is fine at cinema distance.
                    if let thumb = coordinator.sprites.thumbnail(at: target) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 416, height: 234)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(.white.opacity(0.35), lineWidth: 2)
                            }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        Text(Self.clock(target))
                            .font(.system(size: 46, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.92))
                        Text(Self.signedDelta(target - player.currentTime))
                            .font(.system(size: 30, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                        if let label = ScrubSpeed.label(coordinator.scrubTier) {
                            Text(label)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 14).padding(.vertical, 5)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            Capsule().fill(.white.opacity(0.92))
                                .frame(width: player.duration > 0
                                       ? geo.size.width * min(1, max(0, target / player.duration)) : 0)
                        }
                    }
                    .frame(width: 1152, height: 8)
                }
                .padding(.vertical, 28).padding(.horizontal, 48)
                .background(Color.black.opacity(0.40), in: RoundedRectangle(cornerRadius: 20))
                .padding(.bottom, 54)
            }
        }
    }

    // MARK: - Speed pill (top-centre, transient)

    /// Answers the remote's vertical speed-drag: the actual engine rate (truthful during 2×-hold),
    /// plus an AI badge once the interpolation runner is live on the slow rungs.
    @ViewBuilder
    private func speedPill(_ player: ScenePlayerModel) -> some View {
        if coordinator.speedPulse > 0 {
            VStack {
                HStack(spacing: 16) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 30, weight: .medium))
                    Text(Self.rate(player.playbackRate))
                        .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    if player.slowMoActive {
                        aiBadge
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 30).padding(.vertical, 18)
                .background(Color.black.opacity(0.40), in: Capsule())
                .padding(.top, 64)
                Spacer()
            }
            .id(coordinator.speedPulse)                        // restart the fade on every step
            .task {
                try? await Task.sleep(for: .milliseconds(1400))
                coordinator.speedPulse = 0
            }
            .transition(.opacity)
        }
    }

    // MARK: - Mode chips (top-right, persistent while a mode is on)

    /// Quiet standing indicators for the two easy-to-forget states: digital zoom and a non-1× rate.
    /// Dim and small so they read as status, not chrome; gone entirely in the normal case.
    @ViewBuilder
    private func modeChips(_ player: ScenePlayerModel) -> some View {
        let offSpeed = abs(player.playbackRate - 1.0) > 0.001
        if coordinator.isZoomed || offSpeed {
            VStack {
                HStack(spacing: 14) {
                    Spacer()
                    if coordinator.isZoomed {
                        chip {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 22, weight: .medium))
                            Text(String(format: "%.1f×", coordinator.zoomScale))
                                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        }
                    }
                    if offSpeed {
                        chip {
                            Text(Self.rate(player.playbackRate))
                                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            if player.slowMoActive {
                                aiBadge
                            }
                        }
                    }
                }
                .padding(.trailing, 96).padding(.top, 64)
                Spacer()
            }
            .transition(.opacity)
        }
    }

    private func chip(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10, content: content)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color.black.opacity(0.35), in: Capsule())
    }

    private var aiBadge: some View {
        Text("AI")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color.white.opacity(0.16), in: Capsule())
    }

    // MARK: - Volume pill (bottom-right)

    @ViewBuilder
    private func volumePill(_ player: ScenePlayerModel) -> some View {
        if coordinator.volumePulse > 0 {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Image(systemName: player.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 30, weight: .medium))
                        segments(level: player.volume)
                        Text("\(player.volumePercent)%")
                            .font(.system(size: 30, weight: .semibold).monospacedDigit())
                            .frame(width: 90, alignment: .trailing)
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 28).padding(.vertical, 18)
                    .background(Color.black.opacity(0.40), in: Capsule())
                    .padding(.trailing, 96).padding(.bottom, 54)
                }
            }
            .id(coordinator.volumePulse)                       // restart the fade on every change
            .task {
                try? await Task.sleep(for: .milliseconds(1400))
                coordinator.volumePulse = 0
            }
            .transition(.opacity)
        }
    }

    private func segments(level: Double) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<20, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(Double(i) / 20.0 < level ? 0.92 : 0.22))
                    .frame(width: 14, height: 12)
            }
        }
    }

    // MARK: - Loading

    @ViewBuilder
    private func loadingHint(_ player: ScenePlayerModel) -> some View {
        if !player.isReady || player.isBuffering {
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    ProgressView().tint(.white.opacity(0.7)).scaleEffect(1.4)
                    Text(player.isReady ? "Buffering…" : "Loading…")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                .background(Color.black.opacity(0.40), in: Capsule())
                .padding(.bottom, 120)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Formatting

    private static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func signedDelta(_ d: TimeInterval) -> String {
        guard d.isFinite else { return "" }
        let s = Int(d)
        return s < 0 ? "−\(Self.clock(TimeInterval(-s)))" : "+\(Self.clock(TimeInterval(s)))"
    }

    /// "0.25×" / "0.5×" / "1×" / "1.5×" / "2×" — %g drops trailing zeros.
    private static func rate(_ r: Double) -> String {
        guard r.isFinite, r > 0 else { return "1×" }
        return String(format: "%g×", r)
    }
}
