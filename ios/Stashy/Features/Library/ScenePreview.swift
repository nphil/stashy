import SwiftUI
import AVFoundation
import UIKit

// MARK: - Presenter

/// Drives the floating press-and-hold scene preview. A single presenter lives in the
/// environment; cards call `begin`/`scrub`/`end` and a screen-level overlay renders the popup.
@Observable
@MainActor
final class ScenePreviewPresenter {
    struct Active: Identifiable {
        let id: String
        let scene: StashScene
        let apiKey: String
        let sourceRect: CGRect
        var scrubProgress: CGFloat
    }

    var active: Active?

    func begin(scene: StashScene, apiKey: String, sourceRect: CGRect) {
        active = Active(id: scene.id, scene: scene, apiKey: apiKey, sourceRect: sourceRect, scrubProgress: 0)
    }

    /// Map horizontal drag (points) to a 0…1 scrub position. ~260pt sweeps the whole clip.
    func scrub(translationX: CGFloat) {
        guard active != nil else { return }
        let span: CGFloat = 260
        active?.scrubProgress = max(0, min(1, translationX / span))
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

// MARK: - Grid cell (tap navigates, hold previews)

/// Wraps a `SceneCard` with the tap-vs-hold gesture composition. Tapping appends the scene to
/// the navigation path; holding starts the floating preview and scrubs as the finger moves.
struct SceneGridCell: View {
    let scene: StashScene
    let apiKey: String
    @Binding var path: NavigationPath
    var onAppear: () -> Void

    @Environment(\.scenePreviewPresenter) private var presenter
    @State private var frame: CGRect = .zero

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
            .gesture(
                ExclusiveGesture(
                    pressGesture,
                    TapGesture().onEnded { path.append(scene) }
                )
            )
            .onAppear(perform: onAppear)
    }

    private var pressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if presenter?.active?.id != scene.id {
                    presenter?.begin(scene: scene, apiKey: apiKey, sourceRect: frame)
                }
                if let drag {
                    presenter?.scrub(translationX: drag.translation.width)
                }
            }
            .onEnded { _ in presenter?.end() }
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
                ScenePreviewCard(active: active)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: presenter.active?.id)
    }
}

private struct ScenePreviewCard: View {
    let active: ScenePreviewPresenter.Active
    @Environment(\.imageCache) private var imageCache
    @State private var model: PreviewScrubModel?
    @State private var thumbnail: UIImage?

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
        .onAppear {
            if let url = active.scene.previewURL(apiKey: active.apiKey) {
                let m = PreviewScrubModel(url: url)
                m.start()
                model = m
            }
        }
        .task {
            if let url = active.scene.thumbnailURL(apiKey: active.apiKey) {
                thumbnail = try? await imageCache.image(for: url)
            }
        }
        .onChange(of: active.scrubProgress) { _, p in model?.seek(progress: p) }
        .onDisappear { model?.stop() }
    }

    @ViewBuilder private var content: some View {
        if let model {
            PlayerLayerView(player: model.player)
        } else if let thumbnail {
            Image(uiImage: thumbnail).resizable().scaledToFill()
        } else {
            Color.black
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
