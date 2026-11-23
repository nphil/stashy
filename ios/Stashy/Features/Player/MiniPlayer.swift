import SwiftUI
import UIKit

/// Sizes shared by the bar and by the room every tab keeps for it.
enum MiniBarMetrics {
    static let height: CGFloat = 64
    /// From the screen's side edges.
    static let margin: CGFloat = 12
    /// Above the tab bar.
    static let spacing: CGFloat = 8
    /// The video tile: 16:9, inset 8pt inside the bar.
    static let tile = CGSize(width: 85, height: 48)
}

extension View {
    /// Reserves the room for the mini player above the tab bar and, in the selected tab, draws it. Apply to each tab's
    /// content: every tab keeps the same room while a playback is docked, so switching tabs never reflows them.
    func miniBarInset(for tab: AppTab) -> some View {
        modifier(MiniBarInset(tab: tab))
    }
}

private struct MiniBarInset: ViewModifier {
    let tab: AppTab
    @Environment(AppRouter.self) private var router
    @State private var nowPlaying = NowPlaying.shared
    @State private var glasses = GlassesSession.shared

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            // Glasses own the picture while connected: no bar (it returns, paused, when they disconnect).
            if let docked = nowPlaying.docked, !glasses.isConnected {
                Group {
                    if router.selectedTab == tab {
                        MiniPlayerBar(docked: docked)
                    } else {
                        Color.clear.frame(height: MiniBarMetrics.height)
                    }
                }
                .padding(.horizontal, MiniBarMetrics.margin)
                .padding(.bottom, MiniBarMetrics.spacing)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// The minimised player: a glass bar with the live picture, the title, play/pause and close. Tap (or swipe up) to open
/// the full player again; swipe sideways to close it.
struct MiniPlayerBar: View {
    let docked: NowPlaying.Docked
    @State private var nowPlaying = NowPlaying.shared
    @AppStorage(Privacy.key) private var privacyMode = false
    /// Horizontal offset while the bar is being swiped away.
    @State private var dragX: CGFloat = 0

    private var model: ScenePlayerModel { docked.model }
    private static let shape = RoundedRectangle(cornerRadius: CornerRadius.detail, style: .continuous)

    private var subtitle: String? {
        docked.scene.studio?.name ?? docked.scene.performers.first?.name
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.tap(soft: true)
                nowPlaying.expand()
            } label: {
                HStack(spacing: 10) {
                    tile
                    titles
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player")
            .accessibilityHint(docked.scene.displayTitle)

            Button {
                Haptics.tap()
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: MiniBarMetrics.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Button {
                Haptics.tap(soft: true)
                nowPlaying.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: MiniBarMetrics.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: MiniBarMetrics.height)
        .glassEffect(.regular.interactive(), in: Self.shape)
        .overlay {
            // The play position as a hairline along the bottom edge. Its own view: `currentTime` ticks ~10×/s and
            // must re-render this sliver only, never the bar.
            MiniProgressLine(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .clipShape(Self.shape)
                .allowsHitTesting(false)
        }
        .offset(x: dragX)
        .opacity(1 - min(abs(dragX) / 240, 0.7))
        .simultaneousGesture(swipe)
    }

    /// The live picture: the model's render view, moved here from the page once the page has left.
    private var tile: some View {
        MiniPlayerPicture(model: model, isReady: model.isReady, showsPicture: docked.showsPicture)
            .frame(width: MiniBarMetrics.tile.width, height: MiniBarMetrics.tile.height)
            .opacity(docked.showsPicture ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: docked.showsPicture)
            .background(Color.black)
            .overlay {
                // Privacy Mode blurs ALL media. No press-to-peek here — it would fight tap-to-open.
                if privacyMode {
                    BlurEffectView().allowsHitTesting(false)
                } else if model.didFail {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(docked.scene.displayTitle(maxLength: 52))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .privacyTitleBlur()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacyTitleBlur()
            }
        }
    }

    /// Sideways: the bar follows the finger and a throw (or a long enough drag) closes it. Up: opens the player.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) else {
                    if dy < -24 {
                        Haptics.tap(soft: true)
                        nowPlaying.expand()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                    return
                }
                if abs(dx) > 90 || abs(value.predictedEndTranslation.width) > 240 {
                    withAnimation(.easeOut(duration: 0.18)) { dragX = dx < 0 ? -420 : 420 }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(170))
                        nowPlaying.close()
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                }
            }
    }
}

private struct MiniProgressLine: View {
    let model: ScenePlayerModel

    var body: some View {
        let raw = model.duration > 0 ? model.currentTime / model.duration : 0
        let fraction = raw.isFinite ? min(max(raw, 0), 1) : 0
        GeometryReader { geo in
            Rectangle()
                .fill(.tint)
                .frame(width: geo.size.width * fraction)
        }
        .frame(height: 2)
    }
}

/// Hosts the model's render view inside the bar's tile.
///
/// The view is the SAME object the full player shows — playback never reloads — so only one place can hold it at a
/// time. It is attached once per distinct view (an engine rebuild vends a new one) and only after the page has left
/// (`showsPicture`): a later update must never steal it back from the page that has just taken it over.
private struct MiniPlayerPicture: UIViewRepresentable {
    let model: ScenePlayerModel
    /// Read only so that an engine rebuild (which vends a NEW render view) re-runs `updateUIView`.
    let isReady: Bool
    let showsPicture: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = Container()
        container.backgroundColor = .black
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.host(model.renderView, in: container, shown: showsPicture)
    }

    /// Keeps whatever it hosts exactly the size of the tile.
    private final class Container: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            for view in subviews { view.frame = bounds }
        }
    }

    @MainActor
    final class Coordinator {
        private weak var attached: UIView?

        func host(_ view: UIView?, in container: UIView, shown: Bool) {
            guard shown else {
                attached = nil
                return
            }
            guard let view, view !== attached else { return }
            attached = view
            view.removeFromSuperview()
            container.addSubview(view)
            view.frame = container.bounds
        }
    }
}

/// The full player re-opened from the bar: the docked scene's page in its own navigation stack (so performer links still
/// work), presented over the whole app. The page ADOPTS the docked playback (`NowPlaying.adoptableModel`).
///
/// Same shape as the Downloads tab's player cover: the scene is PUSHED onto a themed root, so the left-edge swipe-back
/// pops it and popping past it dismisses the cover.
struct NowPlayingCover: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route]

    init(scene: StashScene) {
        _path = State(initialValue: [Route.scene(scene)])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ThemedBackground().ignoresSafeArea()
                .navigationDestination(for: Route.self) { RouteDestination(route: $0, path: $path) }
        }
        .onChange(of: path) { _, newPath in
            // Popped back past the player: close the cover without a second slide (the revealed backdrop is the app).
            guard newPath.isEmpty else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }
}
