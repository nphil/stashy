import SwiftUI

/// Custom playback controls over the video surface: play/pause, time, fullscreen,
/// and a scrubber that shows Stash sprite-sheet thumbnails while dragging.
struct PlayerControlsView: View {
    let model: ScenePlayerModel
    let sprites: SpriteThumbnails
    @Binding var isFullscreen: Bool
    @Binding var showControls: Bool
    @Binding var showStats: Bool
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
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
                    // Play/pause centred on the actual video rect. Hidden while loading/buffering — the
                    // loading donut shows there instead (so the icon never flickers play↔pause on a
                    // stuttery start).
                    if model.isReady, !model.isLoading {
                        Button { model.togglePlayPause(); scheduleHide() } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                        .position(x: videoRect.midX, y: videoRect.midY)
                        .transition(.opacity)
                    }

                    // Bottom bar. Fullscreen: pin directly to the screen's safe-area bottom — anchoring to
                    // the video rect can push it off-screen if the rect is briefly mis-sized (e.g. a video
                    // whose true aspect arrives late, as some MPEG4/AVI files do). Inline: follow the bottom
                    // edge of the fitted video box (the device bottom inset there belongs to the tab bar).
                    controlBar
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, isFullscreen ? safeArea.bottom : max(proxy.size.height - videoRect.maxY, 0))
                        .padding(.leading, isFullscreen ? safeArea.leading : 0)
                        .padding(.trailing, isFullscreen ? safeArea.trailing : 0)
                        .transition(.opacity)

                    if let onBack {
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
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .onAppear { scheduleHide() }
    }

    private var controlBar: some View {
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

            HStack(spacing: 14) {
                Text(Self.timeString(isScrubbing ? scrubTime : model.currentTime))
                // Debug Stats toggle — fullscreen only (no clutter in the inline app view).
                if isFullscreen {
                    Button { showStats.toggle() } label: {
                        Image(systemName: showStats ? "chart.bar.doc.horizontal.fill" : "chart.bar.doc.horizontal")
                    }
                }
                Spacer()
                Text(Self.timeString(model.duration))
                Button { isFullscreen.toggle() } label: {
                    Image(systemName: isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .padding(.top, 24)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    static func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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
                    // Determinate: a static ring whose fill grows clockwise from the top with the buffer.
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                } else {
                    // Indeterminate (pre-buffer stages): a short arc that spins until progress is known.
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                }
            }
            .frame(width: 48, height: 48)

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
                        isScrubbing = true
                        let p = max(0, min(1, value.location.x / width))
                        scrubTime = Double(p) * duration
                    }
                    .onEnded { _ in
                        onSeek(scrubTime)
                        isScrubbing = false
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
