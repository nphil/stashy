import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @Environment(\.previewCache) private var previewCache
    @State private var showDisconnectAlert = false
    @State private var editingURL = ""
    @State private var editingKey = ""
    @State private var savedURL = ""
    @State private var savedKey = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var cacheSize = 0
    @State private var isClearingCache = false
    @AppStorage("animatedPreviews") private var animatedPreviews = true
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("blurThumbnails") private var blurThumbnails = false
    @AppStorage("blurTitles") private var blurTitles = false

    private let swatchColumns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    private var isConnected: Bool { appState.isAuthenticated }
    private var hasChanges: Bool {
        editingURL.trimmed != savedURL || editingKey.trimmed != savedKey
    }
    private var canSave: Bool { hasChanges && !editingURL.trimmed.isEmpty && !isSaving }

    var body: some View {
        NavigationStack {
            List {
                // Connection status
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(isConnected ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isConnected ? "Connected" : "Not Connected")
                                .font(.subheadline.weight(.semibold))
                            Text(isConnected ? (URL(string: savedURL)?.host() ?? savedURL) : "Enter your server details below")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Server connection fields
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://stash.example.com:9999", text: $editingURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.next)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Leave blank if your server has no login", text: $editingKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.go)
                            .onSubmit { if canSave { saveServer() } }
                    }
                    .padding(.vertical, 2)

                    if let err = saveError {
                        Label(err, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if hasChanges {
                        Button(action: saveServer) {
                            HStack {
                                Spacer()
                                if isSaving {
                                    ProgressView().tint(.white)
                                } else {
                                    Text(isConnected ? "Update & Reconnect" : "Connect")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themeManager.current.accentColor)
                        .disabled(!canSave)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Your Stash server address (including http:// or https:// and port). The API key lives in Stash under Settings → Security → API Key — only needed if your server requires a login.")
                }

                // Disconnect
                if isConnected {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            showDisconnectAlert = true
                        }
                        .frame(maxWidth: .infinity)
                    }
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
                    Text("Show an animated preview when you press and hold a scene card. Turn off for thumbnails only.")
                }

                // Privacy section
                Section {
                    Toggle("Require Face ID", isOn: $appLockEnabled)
                        .disabled(!AppLock.isAvailable)
                    Toggle("Blur thumbnails", isOn: $blurThumbnails)
                    Toggle("Blur titles", isOn: $blurTitles)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(AppLock.isAvailable
                         ? "Require Face ID, Touch ID, or your passcode to open Stashy. Blur thumbnails to obscure imagery throughout the app."
                         : "Set up Face ID, Touch ID, or a passcode in iOS Settings to enable app lock. Blur thumbnails to obscure imagery throughout the app.")
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
                Button("Disconnect", role: .destructive) {
                    appState.disconnect()
                    savedURL = ""; savedKey = ""
                    editingURL = ""; editingKey = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your server URL and API key will be removed from this device.")
            }
            .onAppear {
                savedURL = KeychainService.read("serverURL") ?? ""
                savedKey = KeychainService.read("apiKey") ?? ""
                editingURL = savedURL
                editingKey = savedKey
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
        Task {
            do {
                try await appState.connect(serverURL: editingURL, apiKey: editingKey)
                // Normalize fields to the stored (trimmed) values so the form is no longer "dirty".
                savedURL = KeychainService.read("serverURL") ?? editingURL.trimmed
                savedKey = KeychainService.read("apiKey") ?? editingKey.trimmed
                editingURL = savedURL
                editingKey = savedKey
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

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
