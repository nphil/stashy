import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

struct StashyDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenTransferView(context: context)
                .activityBackgroundTint(.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Stashy", systemImage: context.state.phase.symbol)
                        .font(.headline)
                        .foregroundStyle(.purple)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TransferPercent(state: context.state)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(context.isStale ? "Waiting for update" : context.state.phase.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            if context.state.activeJobCount > 1 {
                                Text("\(context.state.activeJobCount) active")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        TransferProgress(state: context.state)
                        Text(context.isStale ? "Open Stashy to refresh progress" : context.state.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(.purple)
            } compactTrailing: {
                CompactTransferValue(state: context.state)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(.purple)
            }
            .keylineTint(.purple)
        }
    }
}

private struct LockScreenTransferView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: context.state.phase.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.isStale ? "Waiting for update" : context.state.phase.title)
                        .font(.headline)
                    Text(context.isStale ? "Open Stashy to refresh progress" : context.state.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    TransferPercent(state: context.state)
                        .font(.headline.monospacedDigit())
                    if context.state.activeJobCount > 1 {
                        Text("\(context.state.activeJobCount) active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            TransferProgress(state: context.state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct TransferProgress: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        if let start = state.estimatedStart, let end = state.estimatedEnd, start < end, end > .now {
            ProgressView(timerInterval: start...end, countsDown: false)
                .tint(.purple)
        } else if let progress = state.progress {
            ProgressView(value: progress)
                .tint(.purple)
        } else {
            ProgressView()
                .tint(.purple)
        }
    }
}

private struct TransferPercent: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        if let progress = state.progress {
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .contentTransition(.numericText())
        } else {
            Image(systemName: "ellipsis")
        }
    }
}

/// The compact island has room for one short value. Prefer a system-updating countdown while the app is
/// suspended; fall back to the last real percentage when an ETA isn't available yet.
private struct CompactTransferValue: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        if let end = state.estimatedEnd, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true, showsHours: false)
        } else {
            TransferPercent(state: state)
        }
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

    var symbol: String {
        switch self {
        case .downloading: "arrow.down.circle.fill"
        case .waitingForNetwork: "wifi.exclamationmark"
        case .preparing: "shippingbox.fill"
        }
    }
}
