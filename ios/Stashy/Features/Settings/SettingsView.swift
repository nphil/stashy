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
    @AppStorage("privacyMode") private var privacyMode = false
    @AppStorage("appSwitcherBlurEnabled") private var appSwitcherBlur = true
    @AppStorage("watchHeatEnabled") private var watchHeatEnabled = true
    @State private var debugLogging = RemoteLog.isLoggingEnabled
    @State private var debugServer = RemoteLog.server
    @State private var debugTopic = RemoteLog.topic

    private let swatchColumns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    /// A horizontal row of swatches limited to one light/dark variant — used in System mode to pick the
    /// palette for each OS appearance.
    @ViewBuilder
    private func variantPicker(title: String, variant: AppTheme.Variant,
                               selected: AppTheme, onPick: @escaping (AppTheme) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(AppTheme.allCases.filter { $0.variant == variant }) { theme in
                        ThemeSwatch(theme: theme, isSelected: selected == theme) { onPick(theme) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
    }

    /// A labelled slider row for a mesh-tuning value (a 0…1 blend fraction), shown as a percentage. Reads
    /// live from `get` so the drag tracks the ThemeManager (the background updates underneath, in place).
    @ViewBuilder
    private func meshSliderRow(_ title: String, get: @escaping () -> Double,
                               range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(Int((get() * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: get, set: set), in: range)
                .tint(themeManager.current.accentColor)
        }
        .padding(.vertical, 2)
    }

    /// True once the user taps **Edit** on a saved connection. A saved server is otherwise shown as
    /// read-only (greyed) rows so it can't be changed by accident. A not-yet-connected server is always
    /// editable (first-time setup).
    @State private var isEditing = false
    private var isConnected: Bool { appState.isAuthenticated }
    private var connectionEditable: Bool { !isConnected || isEditing }
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
                        if connectionEditable {
                            TextField("https://stash.example.com:9999", text: $editingURL)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .submitLabel(.next)
                        } else {
                            Text(savedURL.isEmpty ? "—" : savedURL)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if connectionEditable {
                            SecureField("Leave blank if your server has no login", text: $editingKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .submitLabel(.go)
                                .onSubmit { if canSave { saveServer() } }
                        } else {
                            Text(savedKey.isEmpty ? "None" : "••••••••••")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    if let err = saveError, connectionEditable {
                        Label(err, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if connectionEditable && hasChanges {
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
                    HStack {
                        Text("Connection")
                        Spacer()
                        // Standard "Edit"/"Cancel" affordance so a saved server can't be changed by accident.
                        if isConnected {
                            Button(isEditing ? "Cancel" : "Edit") {
                                if isEditing {                 // Cancel: discard edits, back to read-only
                                    editingURL = savedURL
                                    editingKey = savedKey
                                    saveError = nil
                                }
                                withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                    .textCase(nil)   // keep the button (and title) title-case, not the header's default caps
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
                Section {
                    Toggle("Match system appearance", isOn: Binding(
                        get: { themeManager.systemMode },
                        set: { themeManager.setSystemMode($0) }
                    ))

                    if themeManager.systemMode {
                        // System mode: pick the palette used for each OS appearance.
                        variantPicker(title: "Light appearance", variant: .light,
                                      selected: themeManager.lightTheme) { themeManager.setLight($0) }
                        variantPicker(title: "Dark appearance", variant: .dark,
                                      selected: themeManager.darkTheme) { themeManager.setDark($0) }
                    } else {
                        LazyVGrid(columns: swatchColumns, spacing: 16) {
                            ForEach(AppTheme.allCases) { theme in
                                ThemeSwatch(
                                    theme: theme,
                                    isSelected: !themeManager.systemMode && themeManager.fixedTheme == theme
                                ) {
                                    themeManager.set(theme)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } header: {
                    Text("Theme")
                } footer: {
                    Text(themeManager.systemMode
                         ? "Stashy follows your device's Light/Dark setting, using the palette you pick for each."
                         : "Pick any of \(AppTheme.allCases.count) palettes, or turn on “Match system appearance” to switch automatically.")
                }

                // Background depth (mesh tuning) — tune the gradient per light/dark, live.
                Section {
                    meshSliderRow("Dark · vibrancy", get: { themeManager.meshVibrancyDark },
                                  range: MeshTuning.vibrancyRange) { themeManager.setMeshVibrancy($0, dark: true) }
                    meshSliderRow("Dark · lift", get: { themeManager.meshLiftDark },
                                  range: MeshTuning.liftRange) { themeManager.setMeshLift($0, dark: true) }
                    meshSliderRow("Light · vibrancy", get: { themeManager.meshVibrancyLight },
                                  range: MeshTuning.vibrancyRange) { themeManager.setMeshVibrancy($0, dark: false) }
                    meshSliderRow("Light · lift", get: { themeManager.meshLiftLight },
                                  range: MeshTuning.liftRange) { themeManager.setMeshLift($0, dark: false) }
                } header: {
                    Text("Background depth")
                } footer: {
                    Text("Tune the themed background gradient. Vibrancy is how strongly the accent colours glow in the corners; Lift is how light the base becomes. Set separately for dark and light palettes.")
                }

                // Scenes section
                Section {
                    Toggle("Animated previews", isOn: $animatedPreviews)
                } header: {
                    Text("Scenes")
                } footer: {
                    Text("Show an animated preview when you press and hold a scene card. Turn off for thumbnails only.")
                }

                // Player section
                Section {
                    Toggle("Watch heat on scrubber", isOn: $watchHeatEnabled)
                    Button("Clear Watch Heat Data", role: .destructive) {
                        WatchHeat.shared.clearAll()
                    }
                    .disabled(!watchHeatEnabled)
                } header: {
                    Text("Player")
                } footer: {
                    Text("While scrubbing, a YouTube-style curve shows the parts you rewatch most. Tracked entirely on this device — nothing is sent anywhere. Turning it off also stops tracking.")
                }

                // Privacy section
                Section {
                    Toggle("Require Face ID", isOn: $appLockEnabled)
                        .disabled(!AppLock.isAvailable)
                    Toggle("Privacy Mode", isOn: $privacyMode)
                    Toggle("Blur in App Switcher", isOn: $appSwitcherBlur)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(AppLock.isAvailable
                         ? "Require Face ID, Touch ID, or your passcode to open Stashy. Privacy Mode blurs all media — thumbnails, names, sprites, and video (press and hold to peek). Blur in App Switcher covers the app whenever you leave it, so the multitasking snapshot never shows what was on screen."
                         : "Set up Face ID, Touch ID, or a passcode in iOS Settings to enable app lock. Privacy Mode blurs all media — thumbnails, names, sprites, and video (press and hold to peek). Blur in App Switcher covers the app whenever you leave it, so the multitasking snapshot never shows what was on screen.")
                }

                // Cache section
                Section {
                    LabeledContent(
                        "Cached previews & images",
                        value: ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)
                    )
                    if ThumbnailPrefetcher.shared.isRunning {
                        HStack {
                            ProgressView(value: ThumbnailPrefetcher.shared.progress)
                            Text("\(ThumbnailPrefetcher.shared.done)/\(ThumbnailPrefetcher.shared.total)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button("Stop") { ThumbnailPrefetcher.shared.cancel() }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Button("Cache All Thumbnails") {
                            if let client = appState.client {
                                ThumbnailPrefetcher.shared.start(client: client, imageCache: imageCache)
                            }
                        }
                        .disabled(appState.client == nil)
                    }
                    Button("Clear Cache", role: .destructive) { clearCache() }
                        .disabled(isClearingCache || cacheSize == 0)
                } header: {
                    Text("Cache")
                } footer: {
                    Text("Preview clips and images are cached on this device for smooth, instant playback. Cache All Thumbnails fetches every scene thumbnail for offline browsing and instant blur placeholders — it runs gently in the background (one at a time). Clearing frees the space; it rebuilds automatically as you browse.")
                }

                // Developer / diagnostics section
                Section {
                    Toggle("Stream debug logs", isOn: $debugLogging)
                        .onChange(of: debugLogging) { _, on in
                            RemoteLog.isLoggingEnabled = on
                            if on { RemoteLog.shared.enable() } else { RemoteLog.shared.disable() }
                        }
                    if debugLogging {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Log server")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("https://ntfy.sh", text: $debugServer)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.callout.monospaced())
                                .onChange(of: debugServer) { _, v in RemoteLog.server = v }
                                .onSubmit { debugServer = RemoteLog.server }
                        }
                        .padding(.vertical, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Topic / channel")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                // ntfy has no delete API, so a fresh random topic is the way to "clear":
                                // old messages orphan and auto-expire on their own.
                                Button {
                                    let fresh = "stashy-dbg-\(UUID().uuidString.prefix(8).lowercased())"
                                    RemoteLog.topic = fresh
                                    debugTopic = fresh
                                } label: {
                                    Label("New topic", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption)
                                }
                            }
                            TextField("stashy-dbg-…", text: $debugTopic)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.callout.monospaced())
                                .onChange(of: debugTopic) { _, v in RemoteLog.topic = v }
                                .onSubmit { debugTopic = RemoteLog.topic }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Streams playback/transcode diagnostics, browse-scroll frame-time metrics, and screenshots via the floating camera button to an ntfy server + topic. Scroll reports separate touch and inertial segments and include FPS, p95/p99/max frame time, hitch rate, missed 120 Hz intervals, and judder. Point \"Log server\" at a self-hosted ntfy (e.g. an Unraid container) to keep it private; on https://ntfy.sh the topic is readable by anyone who knows it. ntfy has no delete command — messages auto-expire (public: ~12h; attachments ~3h) and \"New topic\" abandons the old channel so it clears itself. Off by default.")
                }

                // About section
                Section("About") {
                    LabeledContent("Version", value: appVersion())
                    Link("GitHub", destination: URL(string: "https://github.com/nphil/stashy")!)
                    Link("Stash Docs", destination: URL(string: "https://docs.stashapp.cc")!)
                }
            }
            .scrollContentBackground(.hidden)
            .listRowBackground(themeManager.current.surfaceColor)   // themed cells, not system grey
            .themedBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Disconnect?", isPresented: $showDisconnectAlert) {
                Button("Disconnect", role: .destructive) {
                    appState.disconnect()
                    savedURL = ""; savedKey = ""
                    editingURL = ""; editingKey = ""
                    isEditing = false
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
            .onChange(of: ThumbnailPrefetcher.shared.completionRevision) { _, _ in
                // One exact terminal measurement, after the prefetch task (and its final disk write)
                // has fully unwound. Avoid polling progress or scanning cache directories mid-job.
                Task { await refreshCacheSize() }
            }
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
                isEditing = false   // back to the greyed read-only view
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
