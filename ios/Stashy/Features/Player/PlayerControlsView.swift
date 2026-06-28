import SwiftUI

/// Custom playback controls over the KSPlayer surface: play/pause, time, fullscreen,
/// and a scrubber that shows Stash sprite-sheet thumbnails while dragging.
struct PlayerControlsView: View {
    let model: ScenePlayerModel
    let sprites: SpriteThumbnails
    @Binding var isFullscreen: Bool

    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.opacity(showControls ? 0.2 : 0.001)
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if showControls {
                VStack {
                    Spacer()
                    Button { model.togglePlayPause(); scheduleHide() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    Spacer()
                    controlBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
    }

    private var controlBar: some View {
        VStack(spacing: 4) {
            ScrubBar(
                duration: model.duration,
                currentTime: model.currentTime,
                sprites: sprites,
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
                if isScrubbing, let image = sprites.thumbnail(at: scrubTime) {
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
