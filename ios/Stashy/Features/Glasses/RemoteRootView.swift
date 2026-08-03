import SwiftUI

/// The phone while glasses are connected: a fullscreen eyes-free remote. True black (OLED off); one
/// glanceable status card up top; everything else is gesture surface. All feedback renders on the
/// GLASSES — the phone's job is to be felt, not looked at.
///
/// v2 vocabulary (volume moved to the hardware buttons, freeing the vertical axis):
///   browse:   drag/flick = focus (52 pt per step), tap = play
///   playback: tap = play/pause · double-tap halves = ±10 s · H-drag = scrub (4-gear by vertical offset)
///             V-drag = speed ladder 0.25→2× (slow rungs get AI interpolation on the glasses)
///             long-press = 2× while held · two-finger tap = mute · pinch = zoom, drags pan while
///             zoomed, double-tap resets
struct RemoteRootView: View {
    @Bindable var coordinator: GlassesCoordinator
    @State private var lock = AppLockState.shared
    @State private var remoteLocked = false
    @State private var exitHold: Task<Void, Never>?

    // Scrub session state
    @State private var scrubBase: TimeInterval = 0
    @State private var scrubAccum: TimeInterval = 0
    @State private var lastCue = -1
    // Pinch session state
    @State private var pinchBase: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if lock.isLocked {
                appLockVeil
            } else {
                touchSurface
                // The stick owns the LOWER HALF, layered above the surface as a sibling so neither
                // steals the other's touches. A tap down here still plays/pauses (see `onTap`), so
                // nothing the old vocabulary offered is lost in that region.
                if stickEnabled {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        joystick
                            .frame(maxWidth: .infinity)
                            .frame(height: 422)
                    }
                    .ignoresSafeArea()
                }
                // Chrome sits ABOVE the stick in z-order, but only the chips are hit-testable — the
                // status card and hints already opt out and a Spacer renders nothing, so every touch
                // in the lower half reaches the stick. The chips move to the TOP with the stick
                // enabled: at the bottom they sat in the middle of the stick's field, and on a
                // bezel-less slab the top corners are the only positions findable by touch alone.
                VStack(spacing: 0) {
                    statusCard
                        .padding(.top, 24)
                    if stickEnabled { chipRow.padding(.top, 10) }
                    Spacer()
                    gestureHints
                    if !stickEnabled { chipRow }
                }
                .padding(.horizontal, 20)
                if remoteLocked { lockHint }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: coordinator.player?.didReachEnd ?? false) { _, ended in
            if ended { coordinator.returnToBrowse() }
        }
        // (Re-hosting on readiness now lives in the coordinator's own observation — this view dies
        // with the takeover window, so it could never cover the post-EXIT engine rebuilds.)
        // A lock flip mid-pinch skips the gesture's ended-reset (the handler guards on remoteLocked),
        // which would leave the next pinch starting from a stale base — zoom jump on first use.
        .onChange(of: remoteLocked) { _, _ in pinchBase = nil }
        // Pay the ~30 ms engine start when the remote appears, not on the first touch.
        .task { await StickHaptics.shared.prepare() }
        .onDisappear { StickHaptics.shared.abort() }
    }

    // MARK: - Analog stick

    /// Owner escape hatch: the whole pre-stick gesture vocabulary stays intact and one tap away, so a
    /// bad first impression is never a regression.
    private var stickEnabled: Bool { RemoteRootView.joystickEnabled }

    static var joystickEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "remoteJoystick") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "remoteJoystick") }
    }

    /// Mode is DERIVED, never toggled: the wearer can see the glasses, and a spring-return stick has
    /// no way to display a latched mode it put you in.
    private var stickMode: RemoteJoystick.StickMode {
        switch coordinator.mode {
        case .browse, .grid: return .browse
        case .playing: return coordinator.isZoomed ? .frame : .transport
        }
    }

    private var joystick: some View {
        RemoteJoystick(
            mode: stickMode,
            enabled: !remoteLocked,
            duration: coordinator.player?.duration ?? 0,
            zoomScale: coordinator.zoomScale,
            slowUnavailable: !(coordinator.player?.canSlowForwardNow ?? false),
            onFocusStep: { dx, dy in
                if coordinator.moveFocus(dx: dx, dy: dy) {
                    Haptics.step()
                } else {
                    Haptics.tap(soft: true); Haptics.tap(soft: true)
                }
            },
            onSelect: {
                Haptics.notify(.success)
                coordinator.selectFocused()
            },
            onTap: { coordinator.togglePlayPause() },
            onTwoFingerTap: {
                switch coordinator.mode {
                case .playing: coordinator.toggleMute()
                case .grid: coordinator.closeGrid()
                case .browse: break
                }
                Haptics.tap()
            },
            onJog: { rung, direction in coordinator.setJog(rung: rung, direction: direction) },
            onShuttle: { rate in
                coordinator.shuttleTick(rate: rate)
                // One tick per sprite cue crossed, so what the hand feels and what the glasses show
                // stay in lockstep (the same rule the old drag-scrub follows).
                if let target = coordinator.scrubTarget, coordinator.sprites.isReady {
                    let cue = coordinator.sprites.cueIndex(at: target)
                    if cue != lastCue { lastCue = cue; Haptics.selectionTick() }
                }
            },
            onShuttleCommit: { coordinator.endShuttle(commit: true); lastCue = -1 },
            onShuttleAbort: { coordinator.endShuttle(commit: false); lastCue = -1 },
            onSpeedStep: { delta in
                if coordinator.stepSpeed(delta) {
                    Haptics.step()
                } else {
                    Haptics.tap(soft: true); Haptics.tap(soft: true)
                }
            },
            onPan: { v, dt in coordinator.panTick(v, dt: dt) },
            onZoomStep: { delta in
                if coordinator.zoomStep(delta) {
                    Haptics.step()
                } else {
                    Haptics.tap(soft: true); Haptics.tap(soft: true)
                }
            }
        )
    }

    // MARK: - Surface

    private var touchSurface: some View {
        RemoteTouchSurface(
            // Test for .playing, NOT for .browse: written the other way round, ANY new mode (the grid)
            // silently inherits the playback gesture set — scrub and pinch instead of focus steps, and
            // onSelect never fires. Compile-clean, device-only.
            mode: coordinator.mode == .playing ? .playback : .browse,
            onFocusStep: { dx, dy in
                if remoteLocked { return }
                if coordinator.moveFocus(dx: dx, dy: dy) {
                    Haptics.step()
                } else {
                    Haptics.tap(soft: true); Haptics.tap(soft: true)
                }
            },
            onSelect: {
                guard !remoteLocked else { return }
                Haptics.notify(.success)
                coordinator.selectFocused()
            },
            onBack: {
                guard !remoteLocked else { return }
                if coordinator.mode == .grid {
                    Haptics.tap(soft: true)
                    coordinator.closeGrid()
                }
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
                // With the stick on, the surface's drag-scrub stands down: two competing scrub
                // mechanisms on one screen is a bug factory, and the stick's variable-rate shuttle
                // supersedes it. Every TAP gesture stays byte-identical either way.
                guard !stickEnabled else { return }
                guard !remoteLocked, let player = coordinator.player else { return }
                if ended {
                    if coordinator.scrubTarget != nil {
                        player.seek(to: max(0, scrubBase + scrubAccum))
                        coordinator.scrubTarget = nil
                        Haptics.tap(soft: true)
                    }
                    return
                }
                if coordinator.scrubTarget == nil {
                    scrubBase = player.currentTime
                    scrubAccum = 0
                    lastCue = -1
                    Haptics.prepareSelection()
                }
                let (rate, tier) = ScrubSpeed.tier(verticalDistance: vertical)
                coordinator.scrubTier = tier
                let width = max(UIScreen.main.bounds.width, 1)
                scrubAccum += Double(dx / width) * max(player.duration, 60) * rate
                // Finite ceiling always — an indefinite stream reports duration 0, and an unbounded
                // target meets Int() downstream (the greatestFiniteMagnitude-is-finite landmine).
                let ceiling = player.duration > 0 ? player.duration - 0.3 : scrubBase + 7200
                let target = max(0, min(scrubBase + scrubAccum, ceiling))
                scrubAccum = target - scrubBase
                coordinator.scrubTarget = target
                // Tick per PREVIEW FRAME crossed (sprite cue), so what the glasses show and what the
                // hand feels stay in lockstep; fall back to 10 s buckets when no sprite index loaded.
                let cue = coordinator.sprites.isReady
                    ? coordinator.sprites.cueIndex(at: target) : Int(target / 10)
                if cue != lastCue { lastCue = cue; Haptics.selectionTick() }
            },
            onSpeedStep: { delta in
                guard !stickEnabled, !remoteLocked else { return }
                if coordinator.stepSpeed(delta) {
                    Haptics.step()
                } else {
                    Haptics.tap(soft: true); Haptics.tap(soft: true)
                }
            },
            onHoldSpeed: { holding in
                guard !remoteLocked else { return }
                coordinator.holdSpeed(holding)
                Haptics.tap()
            },
            onMute: {
                guard !remoteLocked else { return }
                coordinator.toggleMute()
                Haptics.tap()
            },
            isZoomed: { coordinator.isZoomed },
            onPinch: { scale, ended in
                guard !remoteLocked else { return }
                if pinchBase == nil { pinchBase = coordinator.zoomScale; Haptics.tap(soft: true) }
                coordinator.setZoom(scale: (pinchBase ?? 1) * scale, offset: coordinator.zoomOffset)
                if ended { pinchBase = nil; if !coordinator.isZoomed { Haptics.tap(soft: true) } }
            },
            onZoomPan: { dx, dy in
                guard !remoteLocked else { return }
                // Phone points → glasses pixels: ~3× feels 1:1 through the optic (1920 vs ~393 wide).
                coordinator.setZoom(scale: coordinator.zoomScale,
                                    offset: CGPoint(x: coordinator.zoomOffset.x + dx * 3,
                                                    y: coordinator.zoomOffset.y + dy * 3))
            },
            onZoomToggle: {
                guard !remoteLocked else { return }
                coordinator.toggleZoom()
                Haptics.tap()
            }
        )
        .ignoresSafeArea()
    }

    // MARK: - Status card (the one glanceable element)

    private var statusCard: some View {
        HStack(spacing: 14) {
            // NO poster, NO title, ever — not even gated on Privacy Mode. The whole point of watching
            // on the glasses is that the optical path is wearer-only; a phone lying face-up showing
            // the artwork and name of what you're watching hands all of it back (owner, 2026-08-03).
            // The phone renders STATE only: where you are, how long, how fast. The glasses render
            // identity.
            Image(systemName: modeSymbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                switch coordinator.mode {
                case .browse:
                    if coordinator.rails.indices.contains(coordinator.railIndex) {
                        let rail = coordinator.rails[coordinator.railIndex]
                        // The rail NAME is app chrome, not content — every wall has the same three
                        // shelves, so it carries zero bits about which title. A future content-derived
                        // rail (a performer or tag shelf) would be a leak; fail closed on rail ID.
                        Text("\(Self.safeRailTitles.contains(rail.id) ? rail.title : "Rail \(coordinator.railIndex + 1)")  ·  \(coordinator.itemIndex + 1) of \(rail.slotCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                    }
                case .grid:
                    Text("\(coordinator.gridSource?.title ?? "")  ·  \(min(coordinator.gridIndex + 1, max(coordinator.gridTotal, 1))) of \(coordinator.gridTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                case .playing:
                    if let player = coordinator.player {
                        HStack(spacing: 8) {
                            Text(Self.clock(player.currentTime))
                            progressBar(player)
                            Text(Self.clock(player.duration))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08)))
        .allowsHitTesting(false)
    }

    /// State-only glyph — never scene artwork.
    private var modeSymbol: String {
        switch coordinator.mode {
        case .browse: return "square.grid.2x2"
        case .grid: return "square.grid.3x3"
        case .playing: return (coordinator.player?.isPlaying ?? false) ? "play.fill" : "pause.fill"
        }
    }

    /// Rail ids whose TITLE is safe to print on the phone. Keyed on id, not title, so renaming a rail
    /// can't bypass it.
    private static let safeRailTitles: Set<String> = ["played", "added", "downloads"]

    private func progressBar(_ player: ScenePlayerModel) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Color.white.opacity(0.55))
                    .frame(width: player.duration > 0
                           ? geo.size.width * min(1, max(0, player.currentTime / player.duration)) : 0)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Hints + chips

    private var gestureHints: some View {
        Group {
            switch coordinator.mode {
            case .browse:
                Text(stickEnabled ? "Stick ↔ browse  ·  Tap to play" : "Swipe to browse  ·  Tap to play")
            case .grid:
                Text(stickEnabled
                     ? "Stick to browse  ·  Tap to play  ·  Two-finger tap = back"
                     : "Swipe to browse  ·  Tap to play  ·  Two-finger tap to go back")
            case .playing:
                Text(stickEnabled
                     ? (coordinator.isZoomed
                        ? "Stick pans  ·  ↕ past the notch = zoom  ·  Double-tap resets"
                        : "Stick → slow-mo · push further = shuttle  ·  ↕ = speed  ·  Pinch = zoom")
                     : (coordinator.isZoomed
                        ? "Drag to pan  ·  Double-tap to reset zoom"
                        : "Drag ↔ scrub   ↕ speed  ·  Pinch to zoom  ·  Volume buttons for sound"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.22))
        .padding(.bottom, 14)
        .allowsHitTesting(false)
    }

    private var chipRow: some View {
        HStack(spacing: 12) {
            if coordinator.mode == .playing {
                chip("Browse", systemImage: "square.grid.2x2") {
                    Haptics.tap(soft: true)
                    coordinator.returnToBrowse()
                }
            }
            if coordinator.mode == .grid {
                chip("Back", systemImage: "chevron.left") {
                    Haptics.tap(soft: true)
                    coordinator.closeGrid()
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
        .padding(.bottom, 26)
    }

    private func chip(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func holdChip(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Label(label, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
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
                .padding(.top, 90)
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

    // MARK: - Helpers

    private static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
