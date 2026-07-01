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

private struct DownloadCard: View {
    @Bindable var item: DownloadItem
    var onPlay: () -> Void
    @Environment(DownloadManager.self) private var downloads
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.imageCache) private var imageCache
    @State private var thumb: UIImage?
    @State private var performer: UIImage?
    @State private var confirmDelete = false

    var body: some View {
        // Centre-aligned so the scene thumbnail sits vertically centred against the taller text column.
        HStack(alignment: .center, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeManager.current.foregroundColor)
                        .lineLimit(1)
                    Text(item.ext.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(themeManager.current.backgroundColor, in: RoundedRectangle(cornerRadius: 4))
                    Spacer(minLength: 0)
                }

                performerChip

                FlowLayout(spacing: 6) {
                    ForEach(specs, id: \.self) { spec in
                        Text(spec)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(themeManager.current.backgroundColor, in: Capsule())
                    }
                }

                if item.state != .completed { connectionBar }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    controls
                }
            }
        }
        .padding(12)
        .background(themeManager.current.surfaceColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onPlay)   // the control buttons intercept their own taps
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
    }

    /// Performer thumbnail (30% larger than before) with the performer's name alongside. Shown whenever
    /// the scene has a performer; falls back to a person glyph until the image loads.
    @ViewBuilder private var performerChip: some View {
        if item.performerName != nil || item.performerImageURL != nil {
            HStack(spacing: 7) {
                Group {
                    if let performer {
                        Image(uiImage: performer).resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.fill").resizable().scaledToFit()
                            .padding(8).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .background(themeManager.current.backgroundColor)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))

                if let name = item.performerName {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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

    private var controls: some View {
        HStack(spacing: 8) {
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
                iconButton("wand.and.stars", disabled: true) {}   // on-device transcode — M3
                iconButton("trash", tint: .red) { confirmDelete = true }
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
        var out: [String] = []
        if let r = item.resolutionLabel { out.append(r) }
        if let c = item.codecLabel { out.append(c) }
        if let b = item.bitrateLabel { out.append(b) }
        if let s = item.sizeLabel { out.append(s) }
        return out
    }

    private var statusText: String {
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
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .waitingForNetwork, .paused, .stopped: return .secondary
        default: return themeManager.current.foregroundColor.opacity(0.85)
        }
    }
}
