import SwiftUI

/// The Downloader screen: a live list of download cards (thumbnail + multi-connection coloured progress
/// + stats) and finished offline videos. Reached from a scene's 3-dot menu and from Settings. Tapping a
/// card opens the scene player (playing the local file once downloaded).
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(ThemeManager.self) private var themeManager
    @State private var playing: DownloadItem?

    var body: some View {
        Group {
            if downloads.items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download a scene from its ••• menu to see it here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(downloads.items) { item in
                            DownloadCard(item: item) { if item.scene != nil { playing = item } }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(themeManager.current.backgroundColor.ignoresSafeArea())
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { downloads.pruneStopped() }
        // Leaving the screen wipes finished transcode diagnostics, so returning shows a clean card. An
        // in-flight transcode keeps its box.
        .onDisappear { downloads.clearFinishedTranscodeLogs() }
        .fullScreenCover(item: $playing) { item in
            DownloadPlayerCover(item: item)
        }
    }
}

/// Presents the full scene player for a downloaded item in its own navigation stack (so performer
/// links etc. still work), reusing SceneDetailView — which prefers the local file for playback.
private struct DownloadPlayerCover: View {
    let item: DownloadItem
    @State private var path: [Route] = []

    var body: some View {
        if let scene = item.scene {
            NavigationStack(path: $path) {
                SceneDetailView(scene: scene, path: $path)
                    .navigationDestination(for: Route.self) { RouteDestination(route: $0, path: $path) }
            }
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// Presents a performer's page over the Downloads list (tapping the card's performer chip). Its own
/// navigation stack so pushing scenes/performers works; a Close button dismisses it.
private struct DownloadPerformerCover: View {
    let performer: Performer
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            PerformerDetailView(performer: performer, path: $path)
                .navigationDestination(for: Route.self) { RouteDestination(route: $0, path: $path) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                }
        }
    }
}

private struct DownloadCard: View {
    @Bindable var item: DownloadItem
    var onPlay: () -> Void
    @Environment(DownloadManager.self) private var downloads
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @State private var thumb: UIImage?
    @State private var performer: UIImage?
    @State private var confirmDelete = false
    @State private var showTranscode = false
    @State private var showingPerformer: Performer?

    var body: some View {
        // Top-aligned: the thumbnail sits alongside the title/performer top row.
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                // Top row: scene/file name (horizontally scrollable if long) on the left; the tappable
                // performer chip on the right. The name scrolls rather than wrapping, so it never crowds
                // the performer or stretches the card past the screen edge.
                HStack(alignment: .top, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(item.title.isEmpty ? item.fileName : item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(themeManager.current.foregroundColor)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    performerChip
                }

                FlowLayout(spacing: 6) {
                    ForEach(specs, id: \.self) { spec in
                        Text(spec)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(themeManager.current.backgroundColor, in: Capsule())
                    }
                }

                if item.transcoding { transcodeBar }
                else if item.state != .completed { connectionBar }
                transcodeLogBox

                HStack(alignment: .center, spacing: 10) {
                    statusView
                    Spacer(minLength: 8)
                    controls
                }
            }
            // Pin the text column to the available width so a long monospaced log line in the transcode
            // box can't report a huge ideal width and stretch the whole card past the screen edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(themeManager.current.surfaceColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .task(id: thumbKey) { await loadThumb() }
        .task(id: item.performerImageURL) {
            if let url = item.performerImageURL { performer = try? await imageCache.image(for: url, priority: true) }
        }
        .confirmationDialog("Delete this download?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { downloads.delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the downloaded file from this device. It stays in your Stash library.")
        }
        .sheet(isPresented: $showTranscode) {
            TranscodePresetSheet(item: item) { settings in downloads.transcode(item, settings: settings) }
        }
        .fullScreenCover(item: $showingPerformer) { performer in
            DownloadPerformerCover(performer: performer)
        }
    }

    // MARK: - Pieces

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(themeManager.current.backgroundColor)
            if let thumb {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                Image(systemName: "film").font(.title3).foregroundStyle(.tertiary)
            }
            if item.state == .completed {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
        .frame(width: 104, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)   // ONLY the thumbnail opens the player
    }

    /// Tappable performer chip (image + name) pinned to the card's top-right; tapping opens the performer
    /// page (not the video). Falls back to a person glyph until the image loads.
    @ViewBuilder private var performerChip: some View {
        if item.performerName != nil || item.performerImageURL != nil {
            Button {
                if let p = item.scene?.performers.first { showingPerformer = p }
            } label: {
                HStack(spacing: 6) {
                    Group {
                        if let performer {
                            Image(uiImage: performer).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.fill").resizable().scaledToFit()
                                .padding(7).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(themeManager.current.backgroundColor)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15)))

                    if let name = item.performerName {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 96, alignment: .leading)   // cap so the title keeps room
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var connectionBar: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let n = item.connections.count
            let segW = (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n)
            HStack(spacing: spacing) {
                ForEach(item.connections) { conn in
                    ZStack(alignment: .leading) {
                        Capsule().fill(conn.color.opacity(0.18))
                        Capsule().fill(conn.color).frame(width: max(0, segW * conn.progress))
                    }
                    .frame(width: segW)
                }
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.12), value: item.receivedBytes)
    }

    /// Single-bar accent progress shown while an on-device transcode runs.
    private var transcodeBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(themeManager.current.accentColor.opacity(0.18))
                Capsule().fill(themeManager.current.accentColor)
                    .frame(width: max(0, geo.size.width * item.transcodeProgress))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: item.transcodeProgress)
    }

    /// Transcode diagnostics box: append-only event lines (decode path HW/SW, encoder, audio, done) with
    /// the single live status line (fps) pinned under them and updated in place. Shown while transcoding
    /// and afterwards while you stay on the screen; DownloadsView wipes it on disappear. Grows the card
    /// downward and collapses back when the log clears.
    @ViewBuilder private var transcodeLogBox: some View {
        if item.transcoding || !item.transcodeLog.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.transcodeLog.trimmingCharacters(in: .newlines))
                        if !item.transcodeStatus.isEmpty {
                            Text(item.transcodeStatus).foregroundStyle(themeManager.current.accentColor)
                        }
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("logEnd")
                }
                .frame(height: 96)
                .padding(8)
                .background(themeManager.current.backgroundColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                // Only auto-scroll on a NEW event line (not every fps tick), so the box stays readable.
                .onChange(of: item.transcodeLog) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("logEnd", anchor: .bottom) }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if item.transcoding {
                iconButton("xmark", tint: .red) { downloads.cancelTranscode(item) }
            } else {
                switch item.state {
                case .downloading:
                    iconButton("pause.fill") { downloads.pause(item) }
                    iconButton("stop.fill", tint: .red) { downloads.stop(item) }
                case .paused, .waitingForNetwork:
                    iconButton("play.fill") { downloads.resume(item) }
                    iconButton("stop.fill", tint: .red) { downloads.stop(item) }
                case .failed, .stopped:
                    iconButton("arrow.clockwise") { downloads.retry(item) }
                    iconButton("trash", tint: .red) { downloads.delete(item) }
                case .merging, .queued:
                    ProgressView().controlSize(.small)
                case .completed:
                    iconButton("wand.and.stars") { showTranscode = true }   // on-device transcode
                    iconButton("trash", tint: .red) { confirmDelete = true }
                }
            }
        }
    }

    private func iconButton(_ system: String, tint: Color? = nil, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(disabled ? .secondary : (tint ?? themeManager.current.foregroundColor))
                .frame(width: 32, height: 32)
                .background(themeManager.current.backgroundColor, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    // MARK: - Data

    private var thumbKey: String { item.localThumb?.path ?? item.thumbnailURL?.absoluteString ?? item.id }

    private func loadThumb() async {
        if let local = item.localThumb, let img = UIImage(contentsOfFile: local.path) { thumb = img; return }
        if let url = item.thumbnailURL { thumb = try? await imageCache.image(for: url) }
    }

    private var specs: [String] {
        var out: [String] = [item.ext.uppercased()]   // container badge now lives with the other specs
        if let r = item.resolutionLabel { out.append(r) }
        if let c = item.codecLabel { out.append(c) }
        if let b = item.bitrateLabel { out.append(b) }
        if let s = item.sizeLabel { out.append(s) }
        return out
    }

    /// Status row: for a finished download, small rounded "Downloaded" (+ "Transcoded") chips; otherwise
    /// the live status text (queued / downloading / transcoding progress / etc.).
    @ViewBuilder private var statusView: some View {
        if !item.transcoding, item.state == .completed {
            // A completed item only carries an `error` when its last transcode failed — surface it (the
            // chips would otherwise hide it), so the user actually sees why nothing happened.
            if let error = item.error {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    statusChip("Downloaded", color: .green)
                    if item.wasTranscoded { statusChip("Transcoded", color: themeManager.current.accentColor) }
                }
            }
        } else {
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()   // keep each chip on one line; the row has room for both side by side
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var statusText: String {
        if item.transcoding {
            let pct = Int(item.transcodeProgress * 100)
            if let target = item.transcodeTargetLabel { return "Transcoding → \(target) · \(pct)%" }
            return "Transcoding… \(pct)%"
        }
        switch item.state {
        case .queued: return "Queued…"
        case .downloading:
            let pct = Int(item.progress * 100)
            let extra = [item.speedLabel, item.etaLabel].filter { !$0.isEmpty }.joined(separator: " · ")
            return extra.isEmpty ? "\(pct)%" : "\(pct)%  ·  \(extra)"
        case .paused: return "Paused · \(Int(item.progress * 100))%"
        case .waitingForNetwork: return "Waiting for network…"
        case .merging: return "Merging parts…"
        case .completed: return "Downloaded"
        case .failed: return item.error ?? "Failed"
        case .stopped: return "Stopped"
        }
    }

    private var statusColor: Color {
        if item.transcoding { return themeManager.current.accentColor }
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .waitingForNetwork, .paused, .stopped: return .secondary
        default: return themeManager.current.foregroundColor.opacity(0.85)
        }
    }
}

/// Bottom sheet to pick on-device transcode presets (resolution / quality / codec) for a completed
/// download, then kick it off.
private struct TranscodePresetSheet: View {
    let item: DownloadItem
    var onStart: (VideoTranscoder.Settings) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var resolution: TranscodeResolution = .fhd1080
    @State private var quality: TranscodeQuality = .medium
    @State private var codec: TranscodeCodec = .hevc

    var body: some View {
        NavigationStack {
            Form {
                Section("Resolution") {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(TranscodeResolution.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Section("Quality") {
                    Picker("Quality", selection: $quality) {
                        ForEach(TranscodeQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Codec", selection: $codec) {
                        ForEach(TranscodeCodec.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Codec")
                } footer: {
                    Text("HEVC is smaller at the same quality and plays natively on iPhone. Transcoding replaces the offline copy; it stays in your Stash library.")
                }
                Section {
                    Button {
                        onStart(VideoTranscoder.Settings(resolution: resolution, quality: quality, codec: codec))
                        dismiss()
                    } label: {
                        Text("Start Transcode").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Transcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
