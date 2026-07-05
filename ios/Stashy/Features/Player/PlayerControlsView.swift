import SwiftUI

/// Custom playback controls over the video surface: play/pause, time, fullscreen,
/// and a scrubber that shows Stash sprite-sheet thumbnails while dragging.
struct PlayerControlsView: View {
    let model: ScenePlayerModel
    let sprites: SpriteThumbnails
    /// The scene, for the quality/codec status badge (resolution + codec of what's playing).
    let scene: StashScene
    @Binding var isFullscreen: Bool
    @Binding var showControls: Bool
    @Binding var showStats: Bool
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    /// Manual server-transcode quality (gear menu, M-B). Changing it re-routes to the Stash HLS stream.
    @Binding var quality: ServerQuality
    /// Captured right before a quality switch so the rebuilt player resumes at the exact position.
    @Binding var resumeTime: Double
    @State private var showQuality = false
    /// Live frame of the gear button (in the "playerControls" space) so the quality menu can pop up
    /// directly above it instead of floating off in a corner.
    @State private var gearFrame: CGRect = .zero
    /// Measured height of the quality menu, so it can be centred a fixed gap above the gear.
    @State private var menuHeight: CGFloat = 0
    /// Speed menu (playback rate) — mirrors the quality popup: its own visibility, anchor frame, and
    /// measured height, so it pops up directly above the speed pill.
    @State private var showSpeed = false
    @State private var speedFrame: CGRect = .zero
    @State private var speedMenuHeight: CGFloat = 0
    /// The rectangle the video actually occupies (in the controls' coordinate space) — used to centre
    /// the play/pause control and anchor the bottom bar on the real video, not the full player frame.
    var videoRect: CGRect = .zero
    /// Device safe-area insets, so controls clear the notch / Dynamic Island and the home indicator /
    /// side notch in every orientation (the player subtree itself zeroes the safe area).
    var safeArea: EdgeInsets = EdgeInsets()
    /// In portrait-video fullscreen the scrubber sits low on a tall screen, so the sprite preview
    /// is pinned to the top-left instead of floating above the thumb.
    var spritePreviewTopLeading = false
    let scheduleHide: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Dim layer only — taps/zoom/scrub are handled by the zoomable surface underneath, so
                // this never captures touches (otherwise it would block pinch-to-zoom and panning).
                Color.black.opacity(showControls ? 0.2 : 0)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                if showControls {
                    // Transport row: −10s · play/pause · +10s, centred dead-on the video. Hidden while
                    // loading/buffering — the loading donut shows there instead (so the icons never flicker
                    // on a stuttery start). Each button gives haptic feedback.
                    if model.isReady, !model.isLoading {
                        HStack(spacing: 34) {
                            skipButton("gobackward.10") { model.seek(to: max(0, model.currentTime - 10)) }
                            Button {
                                Haptics.tap()
                                model.togglePlayPause(); scheduleHide()
                            } label: {
                                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 40, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                                    .frame(width: 64, height: 64)   // stable box so play↔pause doesn't shift the row
                                    .contentShape(Rectangle())
                            }
                            skipButton("goforward.10") { model.seek(to: min(model.duration, model.currentTime + 10)) }
                        }
                        // Dead-centre of the video (no upward nudge).
                        .position(x: videoRect.midX, y: videoRect.midY)
                        .transition(.opacity)
                    }

                    // Bottom bar. Fullscreen: pin directly to the screen's safe-area bottom — anchoring to
                    // the video rect can push it off-screen if the rect is briefly mis-sized (e.g. a video
                    // whose true aspect arrives late, as some MPEG4/AVI files do). Inline: follow the bottom
                    // edge of the fitted video box (the device bottom inset there belongs to the tab bar).
                    controlBar(landscape: proxy.size.width > proxy.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, isFullscreen ? safeArea.bottom : max(proxy.size.height - videoRect.maxY, 0))
                        .padding(.leading, isFullscreen ? safeArea.leading : 0)
                        .padding(.trailing, isFullscreen ? safeArea.trailing : 0)
                        .transition(.opacity)

                    // Top-corner dismiss. Fullscreen: an ✕ at top-right returns to portrait-inline (the
                    // player keeps playing — no teardown). Inline: a back chevron at top-left leaves the scene.
                    if isFullscreen {
                        Button { isFullscreen = false } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.4), in: Circle())
                                .shadow(radius: 4)
                        }
                        .padding(.trailing, safeArea.trailing + 12)
                        .padding(.top, safeArea.top + 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                    } else if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.4), in: Circle())
                                .shadow(radius: 4)
                        }
                        .padding(.leading, safeArea.leading + 12)
                        .padding(.top, safeArea.top + 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                    }
                }

                // Popup menus (server-quality gear + playback speed) — translucent panels that pop up
                // directly above their button (each button publishes its frame), clamped so they never
                // run off-screen, behind one shared dismiss backdrop.
                if showQuality || showSpeed {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showQuality = false; showSpeed = false } }
                }
                if showQuality {
                    qualityMenu
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
                        .position(popupPosition(anchor: gearFrame, height: menuHeight,
                                                halfWidth: Self.menuHalfWidth, in: proxy.size))
                        .transition(.opacity)
                }
                if showSpeed {
                    speedMenu
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { speedMenuHeight = $0 }
                        .position(popupPosition(anchor: speedFrame, height: speedMenuHeight,
                                                halfWidth: Self.speedMenuHalfWidth, in: proxy.size))
                        .transition(.opacity)
                }

                // Portrait-fullscreen scrub preview, pinned top-left (shows whenever scrubbing).
                if spritePreviewTopLeading, isScrubbing, let image = sprites.thumbnail(at: scrubTime) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 160, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.7), lineWidth: 1))
                        .padding(.leading, safeArea.leading + 16)
                        .padding(.top, safeArea.top + 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: "playerControls")
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .onAppear { scheduleHide() }
    }

    /// Half the fixed width of the quality menu (see `qualityMenu`), used to clamp its pop-up position.
    private static let menuHalfWidth: CGFloat = 89
    /// Half the fixed width of the speed menu (see `speedMenu`).
    private static let speedMenuHalfWidth: CGFloat = 110

    /// Centre a pop-up panel a fixed gap above its anchor button, clamped so it never runs off-screen
    /// (horizontally within the safe area, and never above the top inset).
    private func popupPosition(anchor: CGRect, height: CGFloat, halfWidth: CGFloat, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(anchor.midX, halfWidth + safeArea.leading + 8),
                   size.width - halfWidth - safeArea.trailing - 8),
            y: max(anchor.minY - 12 - height / 2, height / 2 + safeArea.top + 8)
        )
    }

    /// A ±10s skip button: clean `gobackward.10`/`goforward.10` glyph, a comfortable 60pt hit target, and
    /// a light haptic tap on press.
    private func skipButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(soft: true)
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .frame(width: 60, height: 60)
                .contentShape(Rectangle())
        }
    }

    private func controlBar(landscape: Bool) -> some View {
        VStack(spacing: 4) {
            ScrubBar(
                duration: model.duration,
                currentTime: model.currentTime,
                sprites: sprites,
                showSpritePreview: !spritePreviewTopLeading, // top-left variant renders separately
                isScrubbing: $isScrubbing,
                scrubTime: $scrubTime,
                onSeek: { model.seek(to: $0); scheduleHide() }
            )

            // One control row: elapsed · quality + method badges · stats ‖ volume (last on the left) ‖
            // duration · gear · fullscreen. Volume is the final left-hand control and expands rightward
            // into the flexible middle gap, so it never pushes or covers anything; in landscape fullscreen
            // there's far more room, so the track is ~2× wider. Times/badges are fixed-size (never truncate).
            HStack(spacing: 6) {
                Text(Self.timeString(isScrubbing ? scrubTime : model.currentTime))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .fixedSize()
                PlayerStatusBadges(scene: scene, presentationSize: model.presentationSize,
                                   tier: model.playbackTier)
                // Debug Stats toggle — fullscreen only (no clutter in the inline app view).
                if isFullscreen {
                    Button { showStats.toggle() } label: {
                        Image(systemName: showStats ? "chart.bar.doc.horizontal.fill" : "chart.bar.doc.horizontal")
                            .modifier(ControlIcon())
                    }
                }
                // Volume: last item on the left. Wider expanded track in landscape fullscreen.
                VolumeControl(volume: model.volume, isMuted: model.isMuted,
                              onChange: { model.setVolume($0) }, onInteract: { scheduleHide() },
                              trackWidth: (isFullscreen && landscape) ? 120 : 54)
                Spacer(minLength: 6)
                Text(Self.timeString(model.duration))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .fixedSize()
                // Playback-speed pill (Podcasts-style "1×"). Highlighted when not at normal speed. Its
                // frame is published so the speed menu pops up directly above it.
                Button { Haptics.tap(soft: true); withAnimation(.easeOut(duration: 0.15)) { showQuality = false; showSpeed.toggle() }; scheduleHide() } label: {
                    Text(PlaybackSpeed.closest(to: model.playbackRate).label)
                        .font(.system(size: 13, weight: .heavy).monospacedDigit())
                        .foregroundStyle(model.playbackRate == 1 ? .white : Color.accentColor)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("playerControls")) } action: { speedFrame = $0 }
                // Server-quality gear (M-B): pick a manual server-transcode resolution. Its frame is
                // published so the quality menu can pop up directly above it.
                Button { withAnimation(.easeOut(duration: 0.15)) { showSpeed = false; showQuality.toggle() }; scheduleHide() } label: {
                    Image(systemName: quality == .auto ? "gearshape" : "gearshape.fill")
                        .modifier(ControlIcon())
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("playerControls")) } action: { gearFrame = $0 }
                // Enter fullscreen (inline only). Exit is the top-right ✕ — so no exit-fullscreen glyph here.
                if !isFullscreen {
                    Button { isFullscreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .modifier(ControlIcon())
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .padding(.top, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    /// Custom translucent quality picker that blends with the video behind it but stays legible.
    private var qualityMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Server Quality")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 5)
            ForEach(ServerQuality.allCases) { q in
                Button {
                    // Remember exactly where we are so the rebuilt player resumes here, not from 0.
                    resumeTime = isScrubbing ? scrubTime : model.currentTime
                    quality = q
                    withAnimation(.easeOut(duration: 0.15)) { showQuality = false }
                } label: {
                    HStack(spacing: 8) {
                        Text(q.label)
                        Spacer(minLength: 12)
                        if q == quality { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                    }
                    .font(.subheadline.weight(q == quality ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 178)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)   // keep the material dark/legible over video
    }

    /// Playback-speed picker (same translucent style as the quality menu). Selecting a rung keeps the menu
    /// open so the sub-1× "mute when slowed" toggle at the bottom can be flipped without reopening it.
    private var speedMenu: some View {
        let current = PlaybackSpeed.closest(to: model.playbackRate)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Playback Speed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 5)
            ForEach(PlaybackSpeed.allCases) { s in
                Button {
                    Haptics.tap(soft: true)
                    model.setPlaybackRate(s.rawValue)
                } label: {
                    HStack(spacing: 8) {
                        Text(s == .normal ? "Normal (1×)" : s.label)
                        Spacer(minLength: 12)
                        if s == current { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                    }
                    .font(.subheadline.weight(s == current ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(.white.opacity(0.15))
            // Slow-motion audio behaviour: mute below 1× vs. keep pitch-corrected audio at the slow speed.
            Button {
                Haptics.tap(soft: true)
                model.muteWhenSlowed.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.muteWhenSlowed ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                    Text("Mute when slowed")
                    Spacer(minLength: 12)
                    Image(systemName: model.muteWhenSlowed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.muteWhenSlowed ? .white : .white.opacity(0.4))
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Opt-in AI frame-interpolated slow-mo (default off) — Apple's VTFrameProcessor can hard-crash on
            // some files, so it must be explicitly enabled. Only meaningful at ≤0.5× on a slow-playable stream.
            Button {
                Haptics.tap(soft: true)
                model.aiSlowMoEnabled.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").frame(width: 18)
                    Text("AI slow-mo (beta)")
                    Spacer(minLength: 12)
                    Image(systemName: model.aiSlowMoEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.aiSlowMoEnabled ? .white : .white.opacity(0.4))
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 220)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)   // keep the material dark/legible over video
    }

    static func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Shared styling for the bottom-bar icon buttons: a legible glyph on a 44pt square hit target so
/// neighbouring controls don't collect accidental taps.
struct ControlIcon: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// Loading indicator shown over the video while it's buffering: a gently-spinning ring whose fill arc
/// tracks the start-up buffer (`progress`, nil = indeterminate), with a short, light caption naming the
/// current stage (connecting / reading / remuxing / transcoding / buffering) so the wait has feedback and
/// the slow part is obvious.
struct VideoLoadingIndicator: View {
    var progress: Double?
    var message: String
    @State private var spin = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 4)
                if let progress {
                    // Determinate: a static ring whose fill grows clockwise from the top with the
                    // (estimate-blended) load progress, with the live percentage inside it.
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.25), value: progress)
                    Text("\(Int((max(0, min(1, progress)) * 100).rounded()))%")
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                } else {
                    // Indeterminate (pre-buffer stages): a short arc that spins until progress is known.
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                }
            }
            .frame(width: 62, height: 62)

            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .shadow(color: .black.opacity(0.5), radius: 3)
        }
        .onAppear { spin = true }
    }
}

/// Draggable scrubber that overlays a floating sprite thumbnail at the drag position.
struct ScrubBar: View {
    let duration: TimeInterval
    let currentTime: TimeInterval
    let sprites: SpriteThumbnails
    var showSpritePreview = true
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var lastCueIndex = -1

    private let previewWidth: CGFloat = 160
    private let previewHeight: CGFloat = 90

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = duration > 0 ? CGFloat((isScrubbing ? scrubTime : currentTime) / duration) : 0
            let clampedProgress = max(0, min(1, progress))

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                Capsule().fill(.white).frame(width: width * clampedProgress, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .offset(x: width * clampedProgress - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing { Haptics.prepareSelection() }   // drag just began — warm the engine
                        isScrubbing = true
                        let p = max(0, min(1, value.location.x / width))
                        scrubTime = Double(p) * duration
                        // One haptic tick each time the scrub crosses into a new preview frame.
                        let idx = sprites.cueIndex(at: scrubTime)
                        if idx != lastCueIndex {
                            lastCueIndex = idx
                            if idx >= 0 { Haptics.selectionTick() }
                        }
                    }
                    .onEnded { _ in
                        onSeek(scrubTime)
                        isScrubbing = false
                        lastCueIndex = -1
                    }
            )
            .overlay(alignment: .topLeading) {
                if showSpritePreview, isScrubbing, let image = sprites.thumbnail(at: scrubTime) {
                    let x = min(max(width * clampedProgress - previewWidth / 2, 0), width - previewWidth)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: previewWidth, height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.7), lineWidth: 1))
                        .offset(x: x, y: -(previewHeight + 16))
                }
            }
        }
        .frame(height: 22)
    }
}
