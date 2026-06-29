import SwiftUI

enum AppTab: Hashable {
    case scenes, performers, search, settings
}

/// Lightweight cross-screen router: switch tabs and hand the Scenes tab a tag to filter by.
@Observable
@MainActor
final class AppRouter {
    var selectedTab: AppTab = .scenes
    var sceneTagFilter: Tag?

    func openScenes(tag: Tag) {
        sceneTagFilter = tag
        selectedTab = .scenes
    }
}
