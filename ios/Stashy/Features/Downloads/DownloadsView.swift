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
        .onAppear { downloads.pruneStopped(); downloads.downloadsScreenVisible = true }
        // Leaving the screen wipes finished transcode diagnostics, so returning shows a clean card. An
        // in-flight transcode keeps its box.
        .onDisappear { downloads.clearFinishedTranscodeLogs(); downloads.downloadsScreenVisible = false }
        .fullScreenCover(item: $playing) { item in
            DownloadPlayerCover(item: item)
        }
    }
}

/// Presents the full scene player for a downloaded item in its own navigation stack (so performer
/// links etc. still work), reusing SceneDetailView — which prefers the local file for playback.
///
/// The scene is *pushed* onto the stack (over a theme-coloured root) rather than being the root, so the
/// native left-edge swipe-back works exactly like it does in the Library: swiping right pops the player,
/// revealing the backdrop, and popping past it dismisses the cover back to Downloads. The initial path
/// already contains the scene, so there's no entry push animation — the cover still just shows the player.
/// `SceneDetailView` hides the tab bar itself, so this looks identical to the old full-screen presentation.
private struct DownloadPlayerCover: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @State private var path: [Route]

    init(item: DownloadItem) {
        self.item = item
        _path = State(initialValue: item.scene.map { [Route.scene($0)] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            themeManager.current.backgroundColor.ignoresSafeArea()
                .navigationDestination(for: Route.self) { RouteDestination(route: $0, path: $path) }
        }
        .onChange(of: path) { _, newPath in
            // Swiped/popped back past the player → close the cover (cut, not slide — the revealed backdrop
            // already matches the Downloads background, so it reads as a seamless pop back to the list).
            guard newPath.isEmpty else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dismiss() }
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

/// The two download sources offered on a staged card: the original file, or a Server Transcode (always
/// the Stashy Companion plugin pipeline — iPhone-native HEVC/AV1 via its modern ffmpeg).
private enum StageSource: Hashable { case original, serverTranscode }

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
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            if item.state == .staged {
                // Staging: thumbnail + specs sit compactly at the top (right under the title), so the
                // option controls below get the FULL card width — no truncated segments / wrapped menus.
                HStack(alignment: .top, spacing: 12) {
                    thumbnail
                    specsFlow.frame(maxWidth: .infinity, alignment: .leading)
                }
                stagingControls
                actionRow
            } else {
                // Completed / downloading: thumbnail (vertically centered) beside the specs + status column.
                HStack(alignment: .center, spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 8) {
                        specsFlow
                        if item.transcoding { transcodeBar }
                        else if item.state == .serverProcessing { serverProcessingBar }
                        else if item.state != .completed {
                            if item.totalBytes > 0 { connectionBar } else { estimateBar }
                        }
                        transcodeLogBox
                        actionRow
                    }
                    // Pin the column so a long monospaced log line in the transcode box can't stretch the card.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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

    /// Top row spanning the full card: scene/file name at the top-left (scrolls if long), tappable
    /// performer chip at the top-right.
    private var titleRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(item.title.isEmpty ? item.fileName : item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .lineLimit(1)
                    .fixedSize()
                    .privacyTitleBlur()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            performerChip
        }
    }

    /// Media spec chips (container / resolution / codec / bitrate / size), wrapping to as many rows as needed.
    private var specsFlow: some View {
        FlowLayout(spacing: 6) {
            ForEach(specs, id: \.self) { spec in
                Text(spec)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(themeManager.current.backgroundColor, in: Capsule())
            }
        }
    }

    /// Status text (left) + action buttons (right).
    private var actionRow: some View {
        HStack(alignment: .center, spacing: 10) {
            statusView
            Spacer(minLength: 8)
            controls
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(themeManager.current.backgroundColor)
            if let thumb {
                Image(uiImage: thumb).resizable().scaledToFill().privacyImageBlur()
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
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)                          // fits on one line, or two clean lines
                            .multilineTextAlignment(.center)       // both lines centered
                            .minimumScaleFactor(0.7)               // shrink before it would ever truncate
                            .frame(maxWidth: 104, alignment: .center)
                            .privacyTitleBlur()
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

    /// Determinate accent bar for a companion (plugin) server-side transcode. Unlike a live H.264 stream,
    /// the plugin reports real `Job.progress`, so we can show an honest percentage here.
    private var serverProcessingBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(themeManager.current.accentColor.opacity(0.18))
                Capsule().fill(themeManager.current.accentColor)
                    .frame(width: max(0, geo.size.width * item.serverJobProgress))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.3), value: item.serverJobProgress)
    }

    /// Indeterminate bar for a live server transcode: its final size is unknowable up front (Stash sends no
    /// Content-Length), so a % would lie — an earlier estimate sat at 99% while gigabytes kept arriving. A
    /// sliding highlight means "working"; the status line carries the real bytes + speed.
    private var estimateBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let segW = w * 0.35
            TimelineView(.animation) { timeline in
                let period = 1.3
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                ZStack(alignment: .leading) {
                    Capsule().fill(themeManager.current.accentColor.opacity(0.18))
                    Capsule().fill(themeManager.current.accentColor)
                        .frame(width: segW)
                        .offset(x: -segW + (w + segW) * CGFloat(phase))
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
    }

    /// Staged card options before the download starts. Two sources: the Original file (single/multi-thread)
    /// or a Server Transcode — always the Stashy Companion plugin pipeline (HEVC/AV1 via its modern ffmpeg).
    private var stageSource: Binding<StageSource> {
        Binding(
            get: { item.companionCodec != nil ? .serverTranscode : .original },
            set: { newValue in
                switch newValue {
                case .original:        item.companionCodec = nil; item.useServerTranscode = false
                case .serverTranscode: item.useServerTranscode = false
                                       if item.companionCodec == nil { item.companionCodec = .hevc }
                }
            }
        )
    }

    private var companionCodecBinding: Binding<StashCompanion.Codec> {
        Binding(get: { item.companionCodec ?? .hevc }, set: { item.companionCodec = $0 })
    }

    private var stagingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: stageSource) {
                Text("Original").tag(StageSource.original)
                Text("Server Transcode").tag(StageSource.serverTranscode)
            }
            .pickerStyle(.segmented)

            switch stageSource.wrappedValue {
            case .original:
                Picker("Connections", selection: $item.multiThread) {
                    Text("Single").tag(false)
                    Text("Multi-thread").tag(true)
                }
                .pickerStyle(.segmented)
            case .serverTranscode:
                labeledSegment("Codec") {
                    Picker("Codec", selection: companionCodecBinding) {
                        ForEach(StashCompanion.Codec.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                labeledSegment("Resolution") {
                    Picker("Resolution", selection: $item.serverResolution) {
                        ForEach([ServerQuality.original, .p1080, .p720, .p480]) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                labeledSegment("Quality") {
                    Picker("Quality", selection: $item.companionQuality) {
                        ForEach(CompanionQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                // Compact one-liner (no wrap): the live size/ETA estimate shows in the log box once running.
                Text("→ \(companionCodecBinding.wrappedValue.label) · \(item.serverResolution.label)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// A small caption above a full-width control, so segmented pickers stay self-explanatory without a
    /// side label squeezing them (which caused the menu wrapping/truncation).
    private func labeledSegment<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
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
                case .staged:
                    iconButton("arrow.down.to.line", tint: themeManager.current.accentColor) { downloads.beginStaged(item) }
                    iconButton("trash", tint: .red) { downloads.delete(item) }
                case .serverProcessing:
                    ProgressView().controlSize(.small)
                    iconButton("stop.fill", tint: .red) { downloads.stop(item) }
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
                    // Icon-only status badges (no text → nothing to truncate in the width-tight row): green
                    // = downloaded offline, pink/accent = on-device transcoded. SF Symbols are vector, so
                    // they stay crisp at any size.
                    statusBadge("arrow.down.circle.fill", color: .green, label: "Downloaded")
                    if item.wasTranscoded {
                        statusBadge("wand.and.stars", color: themeManager.current.accentColor, label: "Transcoded")
                    }
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

    private func statusBadge(_ symbol: String, color: Color, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)             // square badge, same height as the wand/delete circles
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(label)
    }

    private var statusText: String {
        if item.transcoding {
            let pct = Int(item.transcodeProgress * 100)
            if let target = item.transcodeTargetLabel { return "Transcoding → \(target) · \(pct)%" }
            return "Transcoding… \(pct)%"
        }
        switch item.state {
        case .staged:
            return item.companionCodec != nil ? "Ready to transcode" : "Ready to download"
        case .serverProcessing:
            let pct = Int(item.serverJobProgress * 100)
            if let target = item.transcodeTargetLabel { return "Transcoding → \(target) · \(pct)%" }
            return "Server transcoding · \(pct)%"
        case .queued: return "Queued…"
        case .downloading:
            if item.totalBytes == 0 {   // live server transcode: no size is known — show real bytes + speed
                let got = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
                return item.speedLabel.isEmpty ? "Transcoding · \(got)" : "Transcoding · \(got) · \(item.speedLabel)"
            }
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
        case .serverProcessing: return themeManager.current.accentColor
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
    @State private var detent: PresentationDetent = .large

    /// Instant (pure-arithmetic) estimate of the output size and transcode time for the current presets,
    /// shown inside the Start button. Mirrors the engine's own decisions: a same-codec/same-size job is a
    /// near-instant stream copy (source size); otherwise the target video bitrate × duration, and a time
    /// scaled by how many megapixels/sec the hardware pipeline sustains.
    private var estimate: (size: String, time: String) {
        let srcW = item.width ?? 1280, srcH = item.height ?? 720
        let duration = item.scene?.files.first?.duration ?? 0
        let out = VideoTranscoder.outputSize(naturalSize: CGSize(width: srcW, height: srcH),
                                             maxDimension: resolution.maxDimension)
        let srcCodec = (item.codec ?? "").lowercased()
        let sameCodec = codec == .hevc ? (srcCodec.contains("hevc") || srcCodec.contains("h265"))
                                       : (srcCodec.contains("h264") || srcCodec.contains("avc"))
        let sameSize = out.width == srcW && out.height == srcH

        // No re-encode: stream copy → source size, seconds.
        if sameCodec && sameSize { return (item.sizeLabel ?? "—", "~a few seconds") }

        let fps = 30.0   // source fps isn't stored; 30 is a safe basis for the estimate
        var vbps = Double(VideoTranscoder.videoBitrate(width: out.width, height: out.height, fps: fps,
                                                       quality: quality, codec: codec))
        if sameCodec, let sb = item.bitRate, sb > 100_000 { vbps = min(vbps, Double(sb)) }   // never inflate
        let audioBps = 128_000.0
        let bytes = duration > 0 ? (vbps + audioBps) * duration / 8 : Double(item.totalBytes)
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)

        // Time: total work ≈ outputMegapixels × fps × duration; the A-series pipeline (HW decode + GPU↔CPU
        // + HW encode) sustains ~200 MP/s here. Stream-copy short-circuits above, so this is re-encode only.
        let outMP = Double(out.width * out.height) / 1_000_000
        let secs = duration > 0 ? outMP * fps * duration / 200 : 0
        return (sizeStr, Self.shortDuration(secs))
    }

    private static func shortDuration(_ secs: Double) -> String {
        guard secs >= 1 else { return "~a few seconds" }
        let s = Int(secs.rounded())
        if s < 60 { return "~\(s)s" }
        let m = s / 60, r = s % 60
        if m < 60 { return r > 0 ? "~\(m)m \(r)s" : "~\(m)m" }
        return "~\(m / 60)h \(m % 60)m"
    }

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
                        VStack(spacing: 2) {
                            Text("Start Transcode").fontWeight(.semibold)
                            Text("≈ \(estimate.size) · \(estimate.time)")
                                .font(.caption2)
                                .opacity(0.85)
                        }
                        .frame(maxWidth: .infinity)
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
        // Open tall so the Start button is visible without scrolling; still draggable down to medium.
        .presentationDetents([.medium, .large], selection: $detent)
    }
}
