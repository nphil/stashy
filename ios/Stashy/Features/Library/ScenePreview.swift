import SwiftUI
import AVFoundation
import UIKit

// MARK: - Presenter

@Observable
@MainActor
final class ScenePreviewPresenter {
    struct Active: Identifiable {
        let id: String
        let scene: StashScene
        let apiKey: String
        let sourceRect: CGRect
        let thumbnail: UIImage?
    }

    var active: Active?

    func begin(scene: StashScene, apiKey: String, sourceRect: CGRect, thumbnail: UIImage?) {
        active = Active(id: scene.id, scene: scene, apiKey: apiKey, sourceRect: sourceRect, thumbnail: thumbnail)
    }

    func end() { active = nil }
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

// MARK: - Long-press trigger (coexists with scroll + tap)

/// UIKit long-press (standard delay) with haptic, bridged so it doesn't fight the ScrollView or
/// the card's tap.
struct LongPressTrigger: UIGestureRecognizerRepresentable {
    var onTrigger: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.5 // standard iOS long-press delay
        recognizer.delegate = context.coordinator
        context.coordinator.haptic.prepare()
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began {
            context.coordinator.haptic.impactOccurred()
            onTrigger()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

// MARK: - Grid cell

struct SceneGridCell: View {
    let scene: StashScene
    let apiKey: String
    var onOpen: (StashScene) -> Void
    var onAppear: () -> Void

    @Environment(\.scenePreviewPresenter) private var presenter
    @Environment(\.imageCache) private var imageCache
    @AppStorage("animatedPreviews") private var animatedPreviews = true
    @State private var frame: CGRect = .zero
    @State private var thumbnail: UIImage?

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
            // Don't navigate if a long-press already opened the preview (avoids tap+preview both firing).
            .onTapGesture { if presenter?.active == nil { onOpen(scene) } }
            .gesture(
                LongPressTrigger {
                    guard animatedPreviews else { return }
                    presenter?.begin(scene: scene, apiKey: apiKey, sourceRect: frame, thumbnail: thumbnail)
                }
            )
            .onAppear(perform: onAppear)
            .task(id: scene.id) {
                guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
                thumbnail = try? await imageCache.image(for: url)
            }
    }
}

// MARK: - Overlay host

struct ScenePreviewOverlay: View {
    let presenter: ScenePreviewPresenter
    var onOpen: (StashScene) -> Void

    var body: some View {
        if let active = presenter.active {
            ScenePreviewContainer(active: active, presenter: presenter, onOpen: onOpen)
        }
    }
}

private enum PreviewDrag {
    case none, insidePending, dismiss, outsidePending, scrub, dim
}

private struct ScenePreviewContainer: View {
    let active: ScenePreviewPresenter.Active
    let presenter: ScenePreviewPresenter
    var onOpen: (StashScene) -> Void
    @Environment(\.previewCache) private var previewCache

    @State private var model: PreviewScrubModel?
    @State private var appeared = false
    @State private var dimLevel: CGFloat = 0.45
    @State private var drag: PreviewDrag = .none
    @State private var dismissOffset: CGSize = .zero
    @State private var dragScale: CGFloat = 1
    @State private var pausedProgress: CGFloat = 0
    @State private var dimStart: CGFloat = 0.45

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let popupW = min(geo.size.width - 40, 420)
            let popupH = popupW * 9 / 16
            let restCenter = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let startCenter = CGPoint(x: active.sourceRect.midX - origin.x, y: active.sourceRect.midY - origin.y)
            let startScale = max(active.sourceRect.width / popupW, 0.05)
            let popupFrame = CGRect(
                x: restCenter.x - popupW / 2,
                y: restCenter.y - popupH / 2,
                width: popupW,
                height: popupH
            )

            ZStack {
                Color.black.opacity(appeared ? dimLevel : 0).ignoresSafeArea()

                popupContent
                    .frame(width: popupW, height: popupH)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                    .scaleEffect((appeared ? 1 : startScale) * dragScale)
                    .position(appeared ? restCenter : startCenter)
                    .offset(dismissOffset)
                    .opacity(appeared ? 1 : 0)

                // Touch capture layer on top of everything.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(popupFrame: popupFrame, width: geo.size.width))
            }
            .onAppear {
                loadPlayer()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { appeared = true }
            }
            .onDisappear { model?.stop() }
        }
    }

    private var popupContent: some View {
        ZStack {
            if let thumb = active.thumbnail {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                Color.black
            }
            if let model {
                PlayerLayerView(player: model.player) // .resizeAspectFill → no black bars
            }
        }
    }

    private func loadPlayer() {
        guard let url = active.scene.previewURL(apiKey: active.apiKey) else { return }
        Task {
            guard let local = await previewCache.localURL(for: url) else { return }
            let m = PreviewScrubModel(url: local)
            m.play()
            model = m
        }
    }

    private func dragGesture(popupFrame: CGRect, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if drag == .none {
                    if popupFrame.contains(value.startLocation) {
                        drag = .insidePending
                    } else {
                        drag = .outsidePending
                        model?.pause()
                        pausedProgress = model?.currentProgress ?? 0
                        dimStart = dimLevel
                    }
                }
                let dx = value.translation.width
                let dy = value.translation.height
                switch drag {
                case .insidePending:
                    if dy > 12, abs(dy) > abs(dx) {
                        drag = .dismiss
                        updateDismiss(dy: dy)
                    }
                case .dismiss:
                    updateDismiss(dy: dy)
                case .outsidePending:
                    if abs(dx) > 8 || abs(dy) > 8 {
                        drag = abs(dx) >= abs(dy) ? .scrub : .dim
                    }
                case .scrub:
                    model?.seek(progress: pausedProgress + dx / width)
                case .dim:
                    dimLevel = min(1, max(0, dimStart + dy / 500))
                case .none:
                    break
                }
            }
            .onEnded { value in
                switch drag {
                case .insidePending:
                    openScene()
                case .dismiss:
                    if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dismissOffset = .zero
                            dragScale = 1
                        }
                    }
                case .scrub, .outsidePending, .dim:
                    model?.play() // resume from where the finger left off
                case .none:
                    break
                }
                drag = .none
            }
    }

    private func updateDismiss(dy: CGFloat) {
        dismissOffset = CGSize(width: 0, height: max(0, dy))
        dragScale = max(0.6, 1 - max(0, dy) / 1000)
    }

    private func openScene() {
        let scene = active.scene
        presenter.end()
        onOpen(scene)
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            appeared = false
            dismissOffset = .zero
            dragScale = 1
            dimLevel = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            presenter.end()
        }
    }
}

// MARK: - Scrubbable preview player

@Observable
@MainActor
final class PreviewScrubModel {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
    }

    func play() { player.play() }
    func pause() { player.pause() }

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
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol)
    }

    func stop() { player.pause() }
}
