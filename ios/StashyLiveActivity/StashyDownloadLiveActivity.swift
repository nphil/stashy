import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

private let segmentCount = 8

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
                        LiveSegmentRing(state: context.state)
                            .frame(width: 25, height: 25)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("STASHY")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text(context.isStale ? "Updating" : context.state.phase.shortTitle)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveTransferPercent(state: context.state)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        LiveSegmentBar(state: context.state)
                            .frame(height: 5)
                        HStack(spacing: 8) {
                            Text(context.isStale ? "Open Stashy to refresh" : context.state.status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if context.state.activeJobCount > 1 {
                                Text("+\(context.state.activeJobCount - 1)")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } compactLeading: {
                LiveSegmentRing(state: context.state)
                    .frame(width: 19, height: 19)
            } compactTrailing: {
                LiveTransferPercent(state: context.state)
                    .font(.caption2.weight(.semibold).monospacedDigit())
            } minimal: {
                LiveSegmentRing(state: context.state)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(.purple)
        }
    }
}

/// A deliberately short Lock Screen presentation: identity, percentage, one segmented bar and one status
/// line. The system owns the outer Live Activity container, so reducing internal padding is what keeps the
/// card from looking like an oversized notification.
private struct LockScreenTransferView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>

    var body: some View {
        HStack(spacing: 10) {
            LiveSegmentRing(state: context.state)
                .frame(width: 30, height: 30)
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    Text(context.isStale ? "Updating download" : context.state.phase.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    LiveTransferPercent(state: context.state)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                LiveSegmentBar(state: context.state)
                    .frame(height: 5)
                HStack(spacing: 6) {
                    Text(context.isStale ? "Open Stashy to refresh" : context.state.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if context.state.activeJobCount > 1 {
                        Text("\(context.state.activeJobCount) active")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// Eight arcs represent eight equal byte regions of the featured transfer. Completed regions stay filled,
/// the current region fills continuously, and future regions remain as a quiet track.
private struct LiveSegmentRing: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            SegmentedRing(progress: state.projectedProgress(at: timeline.date), phase: state.phase)
        }
    }
}

private struct SegmentedRing: View {
    let progress: Double?
    let phase: DownloadActivityAttributes.ContentState.Phase

    var body: some View {
        ZStack {
            ForEach(0..<segmentCount, id: \.self) { index in
                let start = CGFloat(index) / CGFloat(segmentCount)
                let end = CGFloat(index + 1) / CGFloat(segmentCount)
                let gap: CGFloat = 0.018
                let filled = segmentProgress(overall: progress, index: index)

                Circle()
                    .trim(from: start + gap, to: end - gap)
                    .stroke(.white.opacity(0.13), style: StrokeStyle(lineWidth: 2.7, lineCap: .round))
                if filled > 0 {
                    Circle()
                        .trim(from: start + gap, to: start + gap + (end - start - gap * 2) * filled)
                        .stroke(segmentColor(index, phase: phase),
                                style: StrokeStyle(lineWidth: 2.7, lineCap: .round))
                }
            }
        }
        .rotationEffect(.degrees(-90))
    }
}

private struct LiveSegmentBar: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let progress = state.projectedProgress(at: timeline.date)
            HStack(spacing: 3) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    GeometryReader { geometry in
                        let filled = segmentProgress(overall: progress, index: index)
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule()
                                .fill(segmentColor(index, phase: state.phase))
                                .frame(width: geometry.size.width * filled)
                        }
                    }
                }
            }
        }
    }
}

private struct LiveTransferPercent: View {
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

private func segmentProgress(overall: Double?, index: Int) -> CGFloat {
    guard let overall else { return 0 }
    return CGFloat(min(1, max(0, overall * Double(segmentCount) - Double(index))))
}

private func segmentColor(_ index: Int, phase: DownloadActivityAttributes.ContentState.Phase) -> Color {
    switch phase {
    case .waitingForNetwork:
        return .orange
    case .preparing:
        return .cyan
    case .downloading:
        let colors: [Color] = [
            Color(red: 0.27, green: 0.78, blue: 1.00),
            Color(red: 0.32, green: 0.62, blue: 1.00),
            Color(red: 0.42, green: 0.48, blue: 1.00),
            Color(red: 0.55, green: 0.39, blue: 1.00),
            Color(red: 0.67, green: 0.34, blue: 0.98),
            Color(red: 0.76, green: 0.34, blue: 0.88),
            Color(red: 0.84, green: 0.38, blue: 0.78),
            Color(red: 0.89, green: 0.44, blue: 0.68)
        ]
        return colors[index % colors.count]
    }
}

private extension DownloadActivityAttributes.ContentState {
    /// Project the last byte snapshot along its measured ETA so the system-owned Live Activity keeps moving
    /// while Stashy's process is suspended. Real delegate updates replace this estimate whenever available.
    func projectedProgress(at date: Date) -> Double? {
        if let start = estimatedStart, let end = estimatedEnd, start < end {
            return min(1, max(0, date.timeIntervalSince(start) / end.timeIntervalSince(start)))
        }
        return progress.map { min(1, max(0, $0)) }
    }
}

private extension DownloadActivityAttributes.ContentState.Phase {
    var shortTitle: String {
        switch self {
        case .downloading: "Download"
        case .waitingForNetwork: "Waiting"
        case .preparing: "Preparing"
        }
    }

    var title: String {
        switch self {
        case .downloading: "Downloading"
        case .waitingForNetwork: "Waiting for network"
        case .preparing: "Preparing download"
        }
    }
}
