import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @Environment(\.previewCache) private var previewCache
    @State private var showDisconnectAlert = false
    @State private var editingURL = ""
    @State private var editingKey = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false
    @State private var cacheSize = 0
    @State private var isClearingCache = false
    @AppStorage("animatedPreviews") private var animatedPreviews = true

    private let swatchColumns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    var body: some View {
        NavigationStack {
            List {
                // Server section
                Section("Server") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Server URL", text: $editingURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        SecureField("API Key", text: $editingKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        if let err = saveError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        if saveSuccess {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }

                        HStack {
                            Button("Save") { saveServer() }
                                .buttonStyle(.glass)
                                .disabled(isSaving || editingURL.isEmpty || editingKey.isEmpty)

                            Spacer()

                            Button("Disconnect", role: .destructive) {
                                showDisconnectAlert = true
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Theme section
                Section("Theme") {
                    LazyVGrid(columns: swatchColumns, spacing: 16) {
                        ForEach(AppTheme.allCases) { theme in
                            ThemeSwatch(
                                theme: theme,
                                isSelected: themeManager.current == theme
                            ) {
                                themeManager.set(theme)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                // Scenes section
                Section {
                    Toggle("Animated previews", isOn: $animatedPreviews)
                } header: {
                    Text("Scenes")
                } footer: {
                    Text("Play scene preview clips on the cards when the grid is at rest. Turn off to show static thumbnails only.")
                }

                // Cache section
                Section {
                    LabeledContent(
                        "Cached previews & images",
                        value: ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)
                    )
                    Button("Clear Cache", role: .destructive) { clearCache() }
                        .disabled(isClearingCache || cacheSize == 0)
                } header: {
                    Text("Cache")
                } footer: {
                    Text("Preview clips and images are cached on this device for smooth, instant playback. Clearing frees the space; it rebuilds automatically as you browse.")
                }

                // About section
                Section("About") {
                    LabeledContent("Version", value: appVersion())
                    Link("GitHub", destination: URL(string: "https://github.com/nphil/stashy")!)
                    Link("Stash Docs", destination: URL(string: "https://docs.stashapp.cc")!)
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.current.backgroundColor.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Disconnect?", isPresented: $showDisconnectAlert) {
                Button("Disconnect", role: .destructive) { appState.disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your server URL and API key will be removed from this device.")
            }
            .onAppear {
                editingURL = KeychainService.read("serverURL") ?? ""
                editingKey = KeychainService.read("apiKey") ?? ""
            }
            .task { await refreshCacheSize() }
        }
    }

    private func refreshCacheSize() async {
        let previews = await previewCache.totalSize()
        let images = await imageCache.diskUsage()
        cacheSize = previews + images
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            await previewCache.clear()
            await imageCache.clear()
            await refreshCacheSize()
            isClearingCache = false
        }
    }

    private func saveServer() {
        isSaving = true
        saveError = nil
        saveSuccess = false
        Task {
            do {
                try await appState.connect(serverURL: editingURL, apiKey: editingKey)
                saveSuccess = true
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
