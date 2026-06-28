import SwiftUI
import AVFoundation
import UIKit

// MARK: - Presenter

/// Drives the floating press-and-hold scene preview. A single presenter lives in the
/// environment; cards call `begin`/`scrub`/`end` and a screen-level overlay renders the popup.
/// The presenter owns the player so scrubbing can anchor to the live playhead (no jump).
@Observable
@MainActor
final class ScenePreviewPresenter {
    struct Active: Identifiable {
        let id: String
        let scene: StashScene
        let apiKey: String
        let sourceRect: CGRect
        let thumbnail: UIImage?
        var scrubProgress: CGFloat
    }

    /// Vertical finger travel (points) that spans the whole clip. Large = fine control.
    private let scrubSpan: CGFloat = 520

    var active: Active?
    private(set) var model: PreviewScrubModel?
    private var anchorProgress: CGFloat?

    func begin(scene: StashScene, apiKey: String, sourceRect: CGRect, thumbnail: UIImage?) {
        anchorProgress = nil
        if let url = scene.previewURL(apiKey: apiKey) {
            let m = PreviewScrubModel(url: url)
            m.start()
            model = m
        }
        active = Active(
            id: scene.id,
            scene: scene,
            apiKey: apiKey,
            sourceRect: sourceRect,
            thumbnail: thumbnail,
            scrubProgress: 0
        )
    }

    /// Relative scrub: `deltaPoints` is upward finger travel since the press point (up = forward).
    /// The first call anchors to the live playhead, so there's no jump when scrubbing starts.
    func scrub(deltaPoints: CGFloat) {
        guard active != nil, let model else { return }
        if anchorProgress == nil { anchorProgress = model.currentProgress }
        let progress = max(0, min(1, (anchorProgress ?? 0) + deltaPoints / scrubSpan))
        active?.scrubProgress = progress
        model.seek(progress: progress)
    }

    func end() {
        model?.stop()
        model = nil
        active = nil
        anchorProgress = nil
    }
}

private struct ScenePreviewPresenterKey: EnvironmentKey {
    static let defaultValue: ScenePreviewPresenter? = nil
}

extension EnvironmentValues {
    var scenePreviewPresenter: ScenePreviewPresenter? {
        get { self[ScenePreviewPresenterKey.self] }
        set { self[ScenePreviewPresenterKey.self] = newValue }
    }
}

// MARK: - 3D-Touch-style long-press + scrub recognizer

/// Bridges a UIKit `UILongPressGestureRecognizer` into SwiftUI. Unlike a SwiftUI `DragGesture`,
/// this fails on pre-trigger movement (so the enclosing `ScrollView` still scrolls) and never
/// competes with a quick tap (so single-tap navigation still works). After it fires (~1s hold)
/// it keeps delivering `.changed` with the live touch location, which drives the scrub.
struct LongPressScrubRecognizer: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void
    /// Upward vertical travel (points) since the press point — positive scrubs forward.
    var onScrub: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 1.0
        recognizer.delegate = context.coordinator
        context.coordinator.haptic.prepare()
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            context.coordinator.anchorY = recognizer.location(in: recognizer.view?.window).y
            context.coordinator.haptic.impactOccurred()
            context.coordinator.haptic.prepare()
            onBegan()
        case .changed:
            guard let anchorY = context.coordinator.anchorY else { return }
            let y = recognizer.location(in: recognizer.view?.window).y
            onScrub(anchorY - y) // finger up -> y decreases -> positive -> forward
        case .ended, .cancelled, .failed:
            context.coordinator.anchorY = nil
            onEnded()
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        var anchorY: CGFloat?

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - Grid cell (tap navigates, hold previews)

/// Wraps a `SceneCard` with the tap-vs-hold gesture composition. A quick tap appends the scene
/// to the navigation path; a 1s hold starts the floating preview and scrubs as the finger moves.
struct SceneGridCell: View {
    let scene: StashScene
    let apiKey: String
    @Binding var path: NavigationPath
    var onAppear: () -> Void

    @Environment(\.scenePreviewPresenter) private var presenter
    @Environment(\.imageCache) private var imageCache
    @State private var frame: CGRect = .zero
    @State private var thumbnail: UIImage?
    @State private var isPreviewing = false

    var body: some View {
        SceneCard(scene: scene, apiKey: apiKey)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, new in frame = new }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                guard !isPreviewing else { return }
                path.append(scene)
            }
            .gesture(
                LongPressScrubRecognizer(
                    onBegan: {
                        isPreviewing = true
                        presenter?.begin(scene: scene, apiKey: apiKey, sourceRect: frame, thumbnail: thumbnail)
                    },
                    onScrub: { presenter?.scrub(deltaPoints: $0) },
                    onEnded: {
                        presenter?.end()
                        // Suppress a stray trailing tap right after release, then re-enable taps.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            isPreviewing = false
                        }
                    }
                )
            )
            .onAppear(perform: onAppear)
            .task(id: scene.id) {
                guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
                thumbnail = try? await imageCache.image(for: url)
            }
    }
}

// MARK: - Floating preview overlay

/// Screen-level overlay; renders the magnified preview without capturing touches so the
/// underlying card gesture keeps driving the scrub.
struct ScenePreviewOverlay: View {
    let presenter: ScenePreviewPresenter

    var body: some View {
        ZStack {
            if presenter.active != nil {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            if let active = presenter.active {
                ScenePreviewCard(active: active, model: presenter.model)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: presenter.active?.id)
    }
}

private struct ScenePreviewCard: View {
    let active: ScenePreviewPresenter.Active
    let model: PreviewScrubModel?

    var body: some View {
        GeometryReader { geo in
            let cardW = max(active.sourceRect.width, 120)
            let popW = min(cardW * 2, geo.size.width - 24)
            let popH = popW * 9 / 16
            let cx = min(max(active.sourceRect.midX, popW / 2 + 12), geo.size.width - popW / 2 - 12)
            let cy = min(max(active.sourceRect.midY, popH / 2 + 40), geo.size.height - popH / 2 - 40)

            content
                .frame(width: popW, height: popH)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottom) {
                    progressBar.padding(10)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .position(x: cx, y: cy)
        }
        .ignoresSafeArea()
    }

    /// Thumbnail sits under a transparent player layer so the popup shows the image instantly
    /// and the video fades in over it — no black flash before the first frame.
    @ViewBuilder private var content: some View {
        ZStack {
            if let thumb = active.thumbnail {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                Color.black
            }
            if let model {
                PlayerLayerView(player: model.player)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                Capsule().fill(.white).frame(width: g.size.width * active.scrubProgress, height: 3)
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Scrubbable preview player

/// A muted, looping preview clip whose playhead can be seeked from a scrub fraction.
@Observable
@MainActor
final class PreviewScrubModel {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
    }

    func start() { player.play() }

    /// Current playhead as a 0…1 fraction of the clip (0 if not ready yet).
    var currentProgress: CGFloat {
        guard let item = player.currentItem else { return 0 }
        let dur = item.duration.seconds
        guard dur.isFinite, dur > 0 else { return 0 }
        return CGFloat(max(0, min(1, player.currentTime().seconds / dur)))
    }

    func seek(progress: CGFloat) {
        guard let item = player.currentItem else { return }
        let dur = item.duration.seconds
        guard dur.isFinite, dur > 0 else { return }
        let clamped = max(0, min(1, progress))
        let time = CMTime(seconds: Double(clamped) * dur, preferredTimescale: 600)
        let tol = CMTime(seconds: 0.2, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol)
    }

    func stop() { player.pause() }
}
