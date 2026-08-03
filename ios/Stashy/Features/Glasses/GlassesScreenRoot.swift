import SwiftUI

/// Content switch for the glasses screen BELOW the video layer: the 10-foot home when signed in with
/// something to show, otherwise the idle card. Video, when attached, covers this entirely.
struct GlassesScreenRoot: View {
    @State private var session = GlassesSession.shared
    @State private var coordinator = GlassesCoordinator.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if coordinator.mode == .playing {
                // NOTHING while playing. This layer sits BELOW the video, and an AVPlayerLayer renders
                // no pixels until its first decoded frame — so during load/buffering the home rails
                // showed straight through the "video". Black here, loading hint on the OSD above.
                Color.black.ignoresSafeArea()
            } else if coordinator.takeoverSuppressed {
                GlassesIdleCard(hint: "Remote closed — resume from your phone")
            } else if coordinator.mode == .grid, let env = session.env {
                GlassesGridView(
                    coordinator: coordinator,
                    imageCache: env.imageCache,
                    apiKey: env.appState.client?.apiKey ?? "",
                    localThumb: { env.downloads.localThumb(sceneID: $0) }
                )
            } else if let env = session.env, env.appState.isAuthenticated, !coordinator.rails.isEmpty {
                GlassesHomeView(
                    coordinator: coordinator,
                    imageCache: env.imageCache,
                    apiKey: env.appState.client?.apiKey ?? "",
                    localThumb: { env.downloads.localThumb(sceneID: $0) }
                )
            } else {
                GlassesIdleCard(hint: session.env == nil ? "" : "Pick something on your phone")
            }
        }
    }
}

/// The OSD layer ABOVE the video: playback feedback plus the remote's exit-hold ring echo.
struct GlassesOSDRoot: View {
    @State private var coordinator = GlassesCoordinator.shared

    var body: some View {
        ZStack {
            GlassesPlaybackOSD(coordinator: coordinator)
            if let progress = coordinator.exitProgress {
                VStack {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().stroke(.white.opacity(0.2), lineWidth: 5)
                            Circle().trim(from: 0, to: progress)
                                .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "iphone")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(width: 72, height: 72)
                        .padding(.trailing, 96).padding(.top, 54)
                    }
                    Spacer()
                }
            }
        }
        .allowsHitTesting(false)
    }
}
