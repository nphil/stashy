import SwiftUI

/// Content of the jobs dropdown: the Stash job Stash is currently running (with a live progress bar that
/// matches Stash's own 0…1 progress), an idle line when nothing is running, a "+N queued" note, and — on the
/// Scenes tab only (`showActions`) — buttons to queue the common library tasks.
///
/// Polling is driven here: `JobMonitor.attach()` on appear (the panel only exists while the dropdown is
/// open) and `.detach()` on disappear, so nothing polls Stash in the background when the panel is closed.
/// Attach/detach is refcounted in the monitor — a rapid close→reopen can deliver the old instance's
/// `onDisappear` after the new instance's `onAppear`, and a plain stop there killed polling for the panel
/// still on screen.
struct JobsPanel: View {
    /// Scenes shows the action buttons; Performers shows the status only (for now).
    var showActions: Bool
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState
    // Whether THIS instance holds a monitor attach — so onDisappear only releases what onAppear took
    // (onAppear can no-op when the client isn't connected yet).
    @State private var attached = false

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
                    actionButton("Compute VMAF Map", "gauge.medium") {
                        await monitor.runCompanionTask(.vmafMap, title: "VMAF map")
                    }
                    actionButton("Compute ThumbHash Map", "square.grid.3x3.fill") {
                        await monitor.runCompanionTask(.thumbhashMap, title: "ThumbHash map")
                    }
                    actionButton("Compute Loudness Map", "speaker.wave.3.fill") {
                        await monitor.runCompanionTask(.loudnessMap, title: "loudness map")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onAppear { if attached == false, let client = appState.client { attached = true; monitor.attach(client: client) } }
        .onDisappear { if attached { attached = false; monitor.detach() } }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        if let err = monitor.actionError {
            // A task tap that failed (plugin not installed / auth / network) — never swallow it silently.
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if monitor.pollFailing {
            // The queue can't be read right now. Saying so beats freezing the last snapshot on screen.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Can't reach Stash — retrying…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let job = monitor.running {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Text(title(job))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeManager.current.foregroundColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)   // wrap cleanly, never truncate mid-word
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Cancel the running job — a clean stop glyph beside the title.
                    Button {
                        Task { await monitor.cancelRunningJob() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(job.status == "STOPPING")   // already stopping
                }
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
        } else if let starting = monitor.starting {
            // Instant feedback for a just-queued task, until the next poll shows the real queue entry.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting \(starting)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if monitor.queuedCount > 0 {
            // Jobs queued but none marked RUNNING yet (brief transition state).
            Text("\(monitor.queuedCount) queued")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Label("Idle — no jobs running", systemImage: "checkmark.circle")
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
