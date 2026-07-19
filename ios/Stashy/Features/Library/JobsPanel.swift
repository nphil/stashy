import SwiftUI

/// Content of the jobs dropdown: the Stash job Stash is currently running (with a live progress bar that
/// matches Stash's own 0…1 progress), an idle line when nothing is running, a "+N queued" note, and — on the
/// Scenes tab only (`showActions`) — buttons to queue the common library tasks.
///
/// Polling is driven here: `JobMonitor.start()` on appear (the panel only exists while the dropdown is open)
/// and `.stop()` on disappear, so nothing polls Stash in the background when the panel is closed.
struct JobsPanel: View {
    /// Scenes shows the action buttons; Performers shows the status only (for now).
    var showActions: Bool
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState

    private var monitor: JobMonitor { JobMonitor.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash jobs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            status

            if showActions {
                Divider().opacity(0.25)
                VStack(spacing: 8) {
                    actionButton("Scan Library", "arrow.clockwise") { await monitor.scanLibrary() }
                    actionButton("Compute VMAF Map", "gauge.medium") { await monitor.runCompanionTask(.vmafMap) }
                    actionButton("Compute ThumbHash Map", "square.grid.3x3.fill") { await monitor.runCompanionTask(.thumbhashMap) }
                    actionButton("Compute Loudness Map", "speaker.wave.3.fill") { await monitor.runCompanionTask(.loudnessMap) }
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onAppear { if let client = appState.client { monitor.start(client: client) } }
        .onDisappear { monitor.stop() }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        if monitor.isIdle {
            Label("Idle — no jobs running", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let job = monitor.running {
            VStack(alignment: .leading, spacing: 7) {
                Text(title(job))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeManager.current.foregroundColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)   // wrap cleanly, never truncate mid-word
                if let p = monitor.progress {
                    ProgressView(value: p)
                        .tint(themeManager.current.accentColor)
                    Text("\(Int((p * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)             // running but indeterminate
                }
                if monitor.queuedCount > 0 {
                    Text("+\(monitor.queuedCount) queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            // Jobs queued but none marked RUNNING yet (brief transition state).
            Text("\(monitor.queuedCount) queued")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Prefer Stash's human-readable job description; fall back to the current sub-task or the raw status.
    private func title(_ job: JobInfo) -> String {
        if !job.description.isEmpty { return job.description }
        if let sub = job.subTasks?.first(where: { !$0.isEmpty }) { return sub }
        return job.status.capitalized
    }

    // MARK: Actions (Scenes only)

    private func actionButton(_ title: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(themeManager.current.foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            // Solid fill (never glass) — the panel itself is glass, and glass-on-glass reads flat.
            .background(themeManager.current.foregroundColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
