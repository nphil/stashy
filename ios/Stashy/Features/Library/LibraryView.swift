import SwiftUI

struct LibraryView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppRouter.self) private var router
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        @Bindable var router = router
        @Bindable var nowPlaying = NowPlaying.shared
        TabView(selection: $router.selectedTab) {
            Tab("Scenes", systemImage: "film.stack", value: AppTab.scenes) {
                ScenesView()
                    .miniBarInset(for: .scenes)
            }
            Tab("Performers", systemImage: "person.2.fill", value: AppTab.performers) {
                PerformersView()
                    .miniBarInset(for: .performers)
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                NavigationStack { DownloadsView() }
                    .miniBarInset(for: .downloads)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
                    .miniBarInset(for: .settings)
            }
        }
        .tint(themeManager.current.accentColor)
        // Apple-Music-style: the glass tab bar minimizes on downward scroll, freeing the screen for
        // content and reading as a floating pill. iPhone-only per the API (this app is iPhone-only).
        .tabBarMinimizeBehavior(.onScrollDown)
        // The mini player re-opens the full player over the whole app (any tab): the cover's page adopts the docked
        // playback, so nothing reloads. See `NowPlaying`.
        .fullScreenCover(item: $nowPlaying.expansion) { expansion in
            NowPlayingCover(scene: expansion.scene)
        }
        // NO forced toolbarBackground on the tab bar: pinning it opaque killed the native scroll-under
        // glass ("immersive") look on Scenes/Performers. The palette still reads through the accent tint
        // and the themed page background beneath the translucent bar.
        // Keep the display awake while watching Downloads or while a download/transcode runs (a
        // foreground-only transcode would otherwise pause when the screen sleeps and the app backgrounds).
        .onChange(of: downloads.keepScreenAwake, initial: true) { _, awake in
            // Through the arbiter, not a direct write: a glasses session also holds the idle timer, and
            // a download finishing mid-session must not re-enable sleep underneath it (locking the phone
            // kills DisplayPort output).
            ScreenAwake.set(.downloads, awake)
        }
        // Glasses own the picture while connected: the bar hides and what is docked pauses.
        .onChange(of: GlassesSession.shared.isConnected) { _, connected in
            nowPlaying.glassesChanged(connected: connected)
        }
    }
}
