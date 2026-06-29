import SwiftUI

@main
struct StashyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeManager = ThemeManager()
    @State private var appState = AppState()
    @State private var imageCache = ImageCache()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(themeManager)
                .environment(appState)
                .environment(\.imageCache, imageCache)
                .preferredColorScheme(themeManager.current.preferredColorScheme)
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

    var body: some View {
        if appState.isAuthenticated {
            LibraryView()
        } else {
            LoginView()
        }
    }
}
