import SwiftUI

struct LibraryView: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        TabView {
            Tab("Scenes", systemImage: "film.stack") {
                ScenesView()
            }
            Tab("Performers", systemImage: "person.2.fill") {
                PerformersView()
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView()
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .tint(themeManager.current.accentColor)
    }
}
