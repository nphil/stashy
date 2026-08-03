import SwiftUI

/// The phone while glasses are connected: a fullscreen eyes-free remote. True black (OLED off), one dim
/// status cluster for the occasional glance, chips along the bottom. Everything else is gesture surface;
/// all feedback renders on the GLASSES, where the eyes are.
struct RemoteRootView: View {
    @Bindable var coordinator: GlassesCoordinator
    @State private var lock = AppLockState.shared
    /// Remote-surface lock (the LOCK chip) — guards against pocket/grip touches. Distinct from app lock.
    @State private var remoteLocked = false
    @State private var exitHold: Task<Void, Never>?

    // Scrub session state (playback mode)
    @State private var scrubBase: TimeInterval = 0
    @State private var scrubAccum: TimeInterval = 0
    @State private var lastCue = -1
    // Volume session state
    @State private var volumeBase: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if lock.isLocked {
                appLockVeil
            } else {
                RemoteTouchSurface(
                    mode: coordinator.mode == .browse ? .browse : .playback,
                    onFocusStep: { dx, dy in
                        if remoteLocked { return }
                        if coordinator.moveFocus(dx: dx, dy: dy) {
                            Haptics.selectionTick(minInterval: 0.03)
                        } else {
                            Haptics.tap(soft: true); Haptics.tap(soft: true)   // hard stop: double-tick
                        }
                    },
                    onSelect: {
                        guard !remoteLocked else { return }
                        Haptics.notify(.success)
                        coordinator.playFocused()
                    },
                    onTogglePlay: {
                        guard !remoteLocked else { return }
                        coordinator.togglePlayPause()
                        Haptics.tap()
                    },
                    onSkip: { side in
                        guard !remoteLocked else { return }
                        coordinator.skip(Double(side) * 10)
                        Haptics.tap(soft: true)
                    },
                    onScrub: { dx, vertical, ended in
                        guard !remoteLocked, let player = coordinator.player else { return }
                        if ended {
                            if coordinator.scrubTarget != nil {
                                player.seek(to: max(0, scrubBase + scrubAccum))
                                coordinator.scrubTarget = nil
                            }
                            return
                        }
                        if coordinator.scrubTarget == nil {          // scrub session begins
                            scrubBase = player.currentTime
                            scrubAccum = 0
                            lastCue = -1
                            Haptics.prepareSelection()
                        }
                        let (rate, tier) = ScrubSpeed.tier(verticalDistance: vertical)
                        coordinator.scrubTier = tier
                        // Relative jog: full width ≈ the whole video at full gear, scaled by the tier.
                        let width = max(UIScreen.main.bounds.width, 1)
                        scrubAccum += Double(dx / width) * max(player.duration, 60) * rate
                        // The ceiling is ALWAYS finite. A local-HLS remux genuinely reports duration 0
                        // while growing, and an unbounded target later meets `Int(target / 10)` — the
                        // documented `.greatestFiniteMagnitude`-is-finite trap that crashed v1.0.332.
                        // Unknown duration ⇒ allow a 2 h forward roam from where the scrub began.
                        let ceiling = player.duration > 0 ? player.duration - 0.3 : scrubBase + 7200
                        let target = max(0, min(scrubBase + scrubAccum, ceiling))
                        scrubAccum = target - scrubBase
                        coordinator.scrubTarget = target
                        let cue = Int(target / 10)                   // tick every 10 s of media crossed
                        if cue != lastCue { lastCue = cue; Haptics.selectionTick() }
                    },
                    onVolume: { dy, ended in
                        guard !remoteLocked, let player = coordinator.player else { return }
                        if ended { return }
                        if volumeBase == 0 { volumeBase = player.volume }
                        let next = min(1, max(0, player.volume + Double(dy) / 400))
                        if Int(next * 100) != player.volumePercent {
                            Haptics.selectionTick()
                        }
                        coordinator.setVolume(next)
                    },
                    onHoldSpeed: { holding in
                        guard !remoteLocked, let player = coordinator.player else { return }
                        player.setPlaybackRate(holding ? 2.0 : 1.0)
                        Haptics.tap()
                    },
                    onMute: {
                        guard !remoteLocked else { return }
                        coordinator.toggleMute()
                        Haptics.tap()
                    }
                )
                .ignoresSafeArea()

                statusCluster
                chipRow
                if remoteLocked { lockHint }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Status (dim, glanceable, burn-in-safe)

    private var statusCluster: some View {
        VStack(spacing: 10) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
            switch coordinator.mode {
            case .browse:
                Text("Browsing on glasses")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.25))
                if !Privacy.isOn, let scene = coordinator.focusedScene {
                    Text(scene.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 44)
                }
            case .playing:
                if let player = coordinator.player {
                    Text("\(Self.clock(player.currentTime)) / \(Self.clock(player.duration))")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.35))
                    Text(player.isPlaying ? "Playing on glasses" : "Paused")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    // MARK: - Chips

    private var chipRow: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                if coordinator.mode == .playing {
                    chip("Browse", systemImage: "square.grid.2x2") {
                        Haptics.tap(soft: true)
                        coordinator.returnToBrowse()
                    }
                }
                holdChip("Exit", systemImage: "iphone") {
                    Haptics.notify(.success)
                    coordinator.player?.pause()
                    coordinator.takeoverSuppressed = true
                }
                chip(remoteLocked ? "Unlock" : "Lock",
                     systemImage: remoteLocked ? "lock.open" : "lock") {
                    remoteLocked.toggle()
                    Haptics.notify(remoteLocked ? .warning : .success)
                }
            }
            .padding(.bottom, 28)
        }
    }

    private func chip(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// EXIT is hold-to-confirm (600 ms) — a tap must never eject the user from the remote, because a
    /// pocket brush taps. Progress echoes on the GLASSES via the coordinator.
    private func holdChip(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Label(label, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.white.opacity(0.07), in: Capsule())
            .onLongPressGesture(minimumDuration: 0.6) {
                coordinator.exitProgress = nil
                action()
            } onPressingChanged: { pressing in
                exitHold?.cancel()
                if pressing {
                    exitHold = Task { @MainActor in
                        for i in 1...12 {
                            try? await Task.sleep(for: .milliseconds(50))
                            guard !Task.isCancelled else { return }
                            coordinator.exitProgress = Double(i) / 12
                        }
                    }
                } else {
                    coordinator.exitProgress = nil
                }
            }
    }

    private var lockHint: some View {
        VStack {
            Text("Remote locked")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
                .padding(.top, 70)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var appLockVeil: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            Text("Unlock Stashy to use the remote")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
