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

// MARK: - Reusable preview gesture

/// Adds tap-to-open + press-hold-to-preview to any scene view (card, row, …) so the preview works
/// everywhere a scene appears. Requires a `scenePreviewPresenter` in the environment and a host
/// `ScenePreviewOverlay`.
struct ScenePreviewGesture: ViewModifier {
    let scene: StashScene
    let apiKey: String
    var onOpen: (StashScene) -> Void

    @Environment(\.scenePreviewPresenter) private var presenter
    @Environment(\.imageCache) private var imageCache
    @AppStorage("animatedPreviews") private var animatedPreviews = true
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            // Track the cell's global frame for the long-press "hero" origin WITHOUT a per-cell background
            // GeometryReader (an extra view node that also re-ran on every scroll frame). onGeometryChange is
            // the efficient, Apple-recommended path and reports the identical .global frame, so the preview's
            // start rect — and thus the animation — is unchanged.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { frame = $0 })
            .contentShape(Rectangle())
            // Don't navigate if a long-press already opened the preview (avoids tap+preview both firing).
            .onTapGesture { if presenter?.active == nil { onOpen(scene) } }
            .gesture(
                LongPressTrigger {
                    guard animatedPreviews else { return }
                    // Resolve the poster from the memory cache synchronously (the visible SceneCard already
                    // loaded it) instead of a second `.task`-driven fetch/decode of the same URL per cell.
                    // A miss just shows black until the clip's first frame — the popup already handles that.
                    let poster = scene.thumbnailURL(apiKey: apiKey).flatMap { imageCache.cachedImage(for: $0) }
                    presenter?.begin(scene: scene, apiKey: apiKey, sourceRect: frame, thumbnail: poster)
                }
            )
    }
}

extension View {
    func scenePreview(_ scene: StashScene, apiKey: String, onOpen: @escaping (StashScene) -> Void) -> some View {
        modifier(ScenePreviewGesture(scene: scene, apiKey: apiKey, onOpen: onOpen))
    }
}

// MARK: - Grid cell

struct SceneGridCell: View {
    let scene: StashScene
    let apiKey: String
    var onOpen: (StashScene) -> Void
    var onAppear: () -> Void

    var body: some View {
        SceneCard(scene: scene, apiKey: apiKey)
            .scenePreview(scene, apiKey: apiKey, onOpen: onOpen)
            .onAppear(perform: onAppear)
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
    @State private var loadTask: Task<Void, Never>?
    @State private var appeared = false
    @State private var dimLevel: CGFloat = 0.45
    @State private var drag: PreviewDrag = .none
    @State private var dismissOffset: CGSize = .zero
    @State private var dragScale: CGFloat = 1
    @State private var pausedProgress: CGFloat = 0
    @State private var dimStart: CGFloat = 0.45
    @State private var lastScrubStep = -1
    @AppStorage(Privacy.key) private var privacyMode = false
    @GestureState private var touching = false   // Privacy Mode: reveal the sprite while a finger is down

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
                    .blur(radius: privacyMode && !touching ? 30 : 0)   // Privacy Mode: hold to peek
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
                    // Privacy Mode peek: a finger down anywhere on the preview reveals it (runs alongside
                    // the scrub/dismiss drag, so it never disturbs that logic).
                    .simultaneousGesture(DragGesture(minimumDistance: 0).updating($touching) { _, s, _ in s = true })
            }
            .onAppear {
                loadPlayer()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { appeared = true }
            }
            .onDisappear { loadTask?.cancel(); model?.stop() }
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
        // Hold the load so onDisappear can cancel it — a long-press dismissed before the clip finishes
        // would otherwise download the whole thing in the background for content that's never watched.
        // Cancellation propagates through the actor await into URLSession.download, aborting the transfer.
        loadTask = Task {
            guard let local = await previewCache.localURL(for: url), !Task.isCancelled else { return }
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
                        if drag == .scrub { Haptics.prepareSelection(); lastScrubStep = -1 }
                    }
                case .scrub:
                    let target = max(0, min(1, pausedProgress + dx / width))
                    model?.seek(progress: target)
                    // The preview is a video (no sprite cues), so quantise the scrub into ~60 steps and
                    // tick per step — quick drag = a flurry, slow = one tap per step, same feel as the player.
                    let step = Int(target * 60)
                    if step != lastScrubStep { lastScrubStep = step; Haptics.selectionTick() }
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
