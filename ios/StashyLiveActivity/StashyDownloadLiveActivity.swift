import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

/// The Dynamic Island's expanded regions sit inside the island's own rounded shape, and the system does
/// NOT inset content away from that curve for you. A previous pass tried 2 pt and the leading character
/// of the bottom status line still clipped on device. This is the value that actually clears it — do not
/// reduce it, and do not reach for `minimumScaleFactor` instead: shrinking the text does not move it away
/// from the curve, which is why that avenue was already spent once.
private let islandInset: CGFloat = 13

struct StashyDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenTransferView(context: context)
                .activityBackgroundTint(Color(red: 0.055, green: 0.055, blue: 0.085).opacity(0.96))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        LiveRing(state: context.state)
                            .frame(width: 24, height: 24)
                        Text("STASHY")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, islandInset)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LivePercent(state: context.state)
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .padding(.trailing, islandInset)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // Everything the owner asked to see, on three tight lines: what it is, how far
                    // along in bytes, and how fast / how long. The bar is continuous — the eight
                    // segments this used to draw represented the eight parallel connections that were
                    // removed in v1.0.313, so they had been decorating a number that no longer existed.
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.state.displayTitle(stale: context.isStale))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LiveBar(state: context.state)
                            .frame(height: 5)
                        HStack(spacing: 0) {
                            Text(context.state.byteLine)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(context.state.rateLine(stale: context.isStale))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, islandInset)
                    .padding(.top, 2)
                }
            } compactLeading: {
                LiveRing(state: context.state)
                    .frame(width: 19, height: 19)
            } compactTrailing: {
                LivePercent(state: context.state)
                    .font(.caption2.weight(.semibold).monospacedDigit())
            } minimal: {
                LiveRing(state: context.state)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(.purple)
        }
    }
}

/// Lock Screen: the fullest presentation, and the one the owner actually watches. Name on top, a
/// continuous bar, then bytes on the left and speed · ETA on the right.
private struct LockScreenTransferView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            LiveRing(state: context.state)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(context.state.displayTitle(stale: context.isStale))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    LivePercent(state: context.state)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                }
                LiveBar(state: context.state)
                    .frame(height: 5)
                HStack(spacing: 0) {
                    Text(context.state.byteLine)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(context.state.rateLine(stale: context.isStale))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if context.state.activeJobCount > 1 {
                        Text(" · +\(context.state.activeJobCount - 1)")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }
}

private struct LiveRing: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let progress = state.projectedProgress(at: timeline.date)
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.14), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Circle()
                    .trim(from: 0, to: CGFloat(progress ?? 0.06))
                    .stroke(state.phase.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

private struct LiveBar: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let progress = state.projectedProgress(at: timeline.date)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule()
                        .fill(state.phase.tint)
                        .frame(width: max(5, geometry.size.width * CGFloat(progress ?? 0)))
                }
            }
        }
    }
}

private struct LivePercent: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            if let progress = state.projectedProgress(at: timeline.date) {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .contentTransition(.numericText())
            } else {
                Text("•••")
            }
        }
    }
}

private extension DownloadActivityAttributes.ContentState {
    /// The scene title when the app sent one. It sends an empty string when Privacy Mode is on, so the
    /// generic phase title is the deliberate fallback rather than a missing-data case.
    func displayTitle(stale: Bool) -> String {
        if stale { return title.isEmpty ? "Updating download" : title }
        return title.isEmpty ? phase.title : title
    }

    /// "744 MB of 4.03 GB". Falls back to what is known when the source had no Content-Length.
    var byteLine: String {
        let received = Self.bytes(receivedBytes)
        guard totalBytes > 0 else { return receivedBytes > 0 ? received : "" }
        return "\(received) of \(Self.bytes(totalBytes))"
    }

    /// "6.2 MB/s · 9m 18s left". Both halves are dropped when unknown rather than shown as zero, and the
    /// whole line yields to the status string whenever the transfer is not actually moving — that is what
    /// carries "Paused — open Stashy to continue" and the network-drop wording.
    func rateLine(stale: Bool) -> String {
        if stale { return "Open Stashy to refresh" }
        guard phase == .downloading, speed > 0 else { return status }
        var parts = [Self.bytes(Int64(speed)) + "/s"]
        if totalBytes > receivedBytes {
            let secs = Int(Double(totalBytes - receivedBytes) / speed)
            parts.append(secs >= 60 ? "\(secs / 60)m \(secs % 60)s left" : "\(secs)s left")
        }
        return parts.joined(separator: " · ")
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Project the last byte snapshot along its measured ETA so the card keeps moving between real
    /// pushes. Real delegate updates replace this estimate whenever they arrive.
    ///
    /// The projection is CLAMPED to a window above the last real byte snapshot and never falls below it.
    /// With the keep-alive running, real pushes land every ~2 s even while backgrounded, so the
    /// projection barely deviates; the wide cap remains for the case where the app IS suspended and the
    /// glide is the only thing keeping the card alive.
    func projectedProgress(at date: Date) -> Double? {
        let real = progress.map { min(1, max(0, $0)) }
        if let start = estimatedStart, let end = estimatedEnd, start < end {
            let projected = min(1, max(0, date.timeIntervalSince(start) / end.timeIntervalSince(start)))
            guard let real else { return projected }
            return min(1, max(real, min(projected, real + 0.35)))
        }
        return real
    }
}

private extension DownloadActivityAttributes.ContentState.Phase {
    var title: String {
        switch self {
        case .downloading: "Downloading"
        case .waitingForNetwork: "Waiting for network"
        case .preparing: "Preparing download"
        }
    }

    var tint: Color {
        switch self {
        case .downloading: Color(red: 0.42, green: 0.55, blue: 1.00)
        case .waitingForNetwork: .orange
        case .preparing: .cyan
        }
    }
}
