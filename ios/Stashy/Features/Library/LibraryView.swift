import SwiftUI

struct LibraryView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppRouter.self) private var router
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab("Scenes", systemImage: "film.stack", value: AppTab.scenes) {
                ScenesView()
            }
            Tab("Performers", systemImage: "person.2.fill", value: AppTab.performers) {
                PerformersView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                NavigationStack { DownloadsView() }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(themeManager.current.accentColor)
        // NO forced toolbarBackground on the tab bar: pinning it opaque killed the native scroll-under
        // glass ("immersive") look on Scenes/Performers. The palette still reads through the accent tint
        // and the themed page background beneath the translucent bar.
        // Keep the display awake while watching Downloads or while a download/transcode runs (a
        // foreground-only transcode would otherwise pause when the screen sleeps and the app backgrounds).
        .onChange(of: downloads.keepScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }
}
