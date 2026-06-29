import SwiftUI

/// Custom playback controls over the KSPlayer surface: play/pause, time, fullscreen,
/// and a scrubber that shows Stash sprite-sheet thumbnails while dragging.
struct PlayerControlsView: View {
    let model: ScenePlayerModel
    let sprites: SpriteThumbnails
    @Binding var isFullscreen: Bool
    @Binding var zoomScale: CGFloat
    var onBack: (() -> Void)? = nil

    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var dragAnchorTime: TimeInterval = 0
    private let scrubHaptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(showControls ? 0.2 : 0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                    .gesture(playerGesture(width: geo.size.width))

                if showControls {
                    VStack {
                        Spacer()
                        // Only show the play/pause control once the video is ready (during
                        // buffering only the spinner shows, never a play button).
                        if model.isReady {
                            Button { model.togglePlayPause(); scheduleHide() } label: {
                                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                            }
                        }
                        Spacer()
                        controlBar
                    }
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
                        .padding(.leading, 12)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showControls)
            .onAppear { scheduleHide() }
            .onDisappear { hideTask?.cancel() }
        }
    }

    /// Press-and-hold then drag to scrub (so it never clashes with panning a zoomed video); a quick
    /// swipe down exits fullscreen (or resets zoom first if zoomed in). Scrubbing maps the horizontal
    /// drag proportionally to the timeline and shows the 100% sprite preview on the bar.
    private func playerGesture(width: CGFloat) -> some Gesture {
        let scrub = LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isScrubbing {
                    isScrubbing = true
                    dragAnchorTime = model.currentTime
                    showControls = true
                    hideTask?.cancel()
                    scrubHaptic.impactOccurred()
                }
                if let drag {
                    let span = max(model.duration, 1)
                    let delta = Double(drag.translation.width / max(width, 1)) * span
                    scrubTime = max(0, min(model.duration, dragAnchorTime + delta))
                }
            }
            .onEnded { _ in
                if isScrubbing {
                    model.seek(to: scrubTime)
                    isScrubbing = false
                    scheduleHide()
                }
            }

        let swipeDown = DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard value.translation.height > 60,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                if zoomScale > 1 {
                    withAnimation(.easeOut(duration: 0.2)) { zoomScale = 1 }
                } else if isFullscreen {
                    isFullscreen = false
                }
            }

        return ExclusiveGesture(scrub, swipeDown)
    }

    private var controlBar: some View {
        VStack(spacing: 4) {
            ScrubBar(
                duration: model.duration,
                currentTime: model.currentTime,
                sprites: sprites,
                showSpritePreview: true, // always show the 100% sprite preview, even when zoomed
                isScrubbing: $isScrubbing,
                scrubTime: $scrubTime,
                onSeek: { model.seek(to: $0); scheduleHide() }
            )

            HStack {
                Text(Self.timeString(isScrubbing ? scrubTime : model.currentTime))
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

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, model.isPlaying, !isScrubbing else { return }
            showControls = false
        }
    }

    static func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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
