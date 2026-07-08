import SwiftUI
import UIKit

@main
struct StashyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeManager = ThemeManager()

    init() {
        // No scroll bars anywhere in the app (chip rows, grids, lists) — hide the indicators globally via
        // the UIScrollView appearance proxy that backs SwiftUI's ScrollView/List.
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }

    @State private var appState = AppState()
    @State private var imageCache = ImageCache()
    @State private var router = AppRouter()
    @State private var libraryEdits = LibraryEdits()
    @State private var downloadManager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(themeManager)
                .environment(appState)
                .environment(router)
                .environment(libraryEdits)
                .environment(downloadManager)
                .environment(\.imageCache, imageCache)
                .preferredColorScheme(themeManager.enforcedColorScheme)
                .tint(themeManager.current.accentColor)
                .appLock()
        }
    }
}

// MARK: - App state

@Observable
@MainActor
final class AppState {
    var client: StashClient?
    var connectionError: String?

    var isAuthenticated: Bool { client != nil }

    init() {
        if let url = KeychainService.read("serverURL"),
           let key = KeychainService.read("apiKey") {
            client = StashClient(serverURL: url, apiKey: key)
        }
    }

    func connect(serverURL: String, apiKey: String) async throws {
        connectionError = nil
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        let candidate = StashClient(serverURL: url, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try await candidate.stats()
        KeychainService.write("serverURL", value: url)
        KeychainService.write("apiKey", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        client = candidate
    }

    func disconnect() {
        KeychainService.delete("serverURL")
        KeychainService.delete("apiKey")
        client = nil
    }
}

// MARK: - Root content view

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    // In system mode `enforcedColorScheme` is nil, so this reflects the real OS appearance; the manager
    // resolves `current` to the matching light/dark palette. (When manual, this equals the forced scheme
    // and is simply ignored.)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if appState.isAuthenticated {
                LibraryView()
            } else {
                LoginView()
            }
        }
        .debugScreenshotOverlay()
        .onChange(of: colorScheme, initial: true) { _, scheme in
            themeManager.systemIsDark = (scheme == .dark)
        }
        // Recolor UIKit chrome (nav bars) to the active palette at launch and on every theme change.
        .onChange(of: themeManager.current, initial: true) { _, theme in
            ThemeChrome.apply(theme)
        }
    }
}
