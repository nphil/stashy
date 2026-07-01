import SwiftUI

/// The Downloader screen: a live list of download cards (multi-connection coloured progress + stats) and
/// finished offline videos. Reached from a scene's 3-dot menu and from Settings.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(ThemeManager.self) private var themeManager

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
                            DownloadCard(item: item)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(themeManager.current.backgroundColor.ignoresSafeArea())
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        // Rows the user stopped while away are pruned on return.
        .onAppear { downloads.pruneStopped() }
    }
}

private struct DownloadCard: View {
    @Bindable var item: DownloadItem
    @Environment(DownloadManager.self) private var downloads
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title + extension.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(themeManager.current.accentColor)
                Text(item.fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .lineLimit(1)
                Text(item.ext.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(themeManager.current.backgroundColor, in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 4)
            }

            // Spec chips.
            FlowLayout(spacing: 6) {
                ForEach(specs, id: \.self) { spec in
                    Text(spec)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(themeManager.current.backgroundColor, in: Capsule())
                }
            }

            // Multi-connection coloured progress (single bar once completed).
            if item.state != .completed {
                connectionBar
            }

            // Status line + controls.
            HStack(spacing: 10) {
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                controls
            }
        }
        .padding(14)
        .background(themeManager.current.surfaceColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
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
                iconButton("trash", tint: .red) { downloads.delete(item) }
            }
        }
    }

    private func iconButton(_ system: String, tint: Color? = nil, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(disabled ? .secondary : (tint ?? themeManager.current.foregroundColor))
                .frame(width: 34, height: 34)
                .background(themeManager.current.backgroundColor, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private var specs: [String] {
        var out: [String] = []
        if let r = item.resolutionLabel { out.append(r) }
        if let c = item.codecLabel { out.append(c) }
        if let b = item.bitrateLabel { out.append(b) }
        if let s = item.sizeLabel { out.append(s) }
        return out
    }

    private var icon: String {
        switch item.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        default: return "arrow.down.circle.fill"
        }
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
