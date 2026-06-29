import SwiftUI

struct LibraryView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab("Scenes", systemImage: "film.stack", value: AppTab.scenes) {
                ScenesView()
            }
            Tab("Performers", systemImage: "person.2.fill", value: AppTab.performers) {
                PerformersView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(themeManager.current.accentColor)
    }
}
