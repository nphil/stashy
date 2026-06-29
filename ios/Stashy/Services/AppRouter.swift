import SwiftUI

enum AppTab: Hashable {
    case scenes, performers, search, settings
}

/// Typed navigation entries for the per-tab `NavigationStack`s. Using an explicit `[Route]` path
/// (instead of scattered `navigationDestination(for:)` modifiers) lets a screen pop back to an
/// already-visited destination instead of pushing a duplicate — e.g. tapping a performer from a
/// scene that was itself opened from that performer pops back to the performer rather than looping.
enum Route: Hashable {
    case scene(StashScene)
    case performer(Performer)
}

/// Renders a `Route` inside a `NavigationStack`, threading the same path binding through so detail
/// screens can push/pop further routes. Declared once per stack via `.navigationDestination(for:)`.
struct RouteDestination: View {
    let route: Route
    @Binding var path: [Route]

    var body: some View {
        switch route {
        case .scene(let scene):
            SceneDetailView(scene: scene, path: $path)
        case .performer(let performer):
            PerformerDetailView(performer: performer, path: $path)
        }
    }
}

extension Array where Element == Route {
    /// Push a performer, or — if it's already on the stack — pop back to it (prevents the
    /// scene⇄performer navigation loop).
    mutating func openPerformer(_ performer: Performer) {
        if let idx = lastIndex(of: .performer(performer)) {
            if idx + 1 < count { removeSubrange((idx + 1)...) }
        } else {
            append(.performer(performer))
        }
    }

    /// Push a scene, or — if it's already on the stack — pop back to it.
    mutating func openScene(_ scene: StashScene) {
        if let idx = lastIndex(of: .scene(scene)) {
            if idx + 1 < count { removeSubrange((idx + 1)...) }
        } else {
            append(.scene(scene))
        }
    }
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
