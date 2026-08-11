import Foundation
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
                // A 2-column grid, NOT a flow: five chips of five different natural widths left a ragged
                // right edge with dead space beside the short ones (owner: "not eye pleasing"). Equal
                // columns give two tidy stacks; the odd fifth spans the full width instead of sitting
                // alone in the left column with a hole next to it.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library tasks")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            taskChip("Scan Library", "arrow.clockwise") { await monitor.scanLibrary() }
                            // Scan ingests; Generate backfills. They are not two strengths of one task —
                            // once a file has a scene, Stash never re-runs the scan-time generators for
                            // it, so this is the only way to fix scenes that came in without sprites.
                            taskChip("Generate", "wand.and.sparkles") { await monitor.generateMedia() }
                        }
                        GridRow {
                            taskChip("VMAF Map", "gauge.medium") {
                                await monitor.runCompanionTask(.vmafMap, title: "VMAF map")
                            }
                            taskChip("ThumbHash Map", "square.grid.3x3.fill") {
                                await monitor.runCompanionTask(.thumbhashMap, title: "ThumbHash map")
                            }
                        }
                        GridRow {
                            taskChip("Loudness Map", "speaker.wave.3.fill") {
                                await monitor.runCompanionTask(.loudnessMap, title: "loudness map")
                            }
                            .gridCellColumns(2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        // Wider than the old 320 so a sub-task line ("Generating sprites for …") has somewhere to go.
        .frame(width: 340, alignment: .leading)
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
            runningStatus(job)
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

    /// The running job, laid out like Stash's own Tasks-page row: title, bar, a meta line, and — the part
    /// that was missing — the live sub-tasks that say what it is chewing on right now.
    @ViewBuilder private func runningStatus(_ job: JobInfo) -> some View {
        let details = subTasks(job)
        let meta = metaLine(job)
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
            } else {
                ProgressView().controlSize(.small)   // running but indeterminate — keep a sign of life
            }

            if !meta.isEmpty {
                Text(meta)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // What Stash is actually doing, straight from the job's `subTasks` — the same lines its web UI
            // prints under the bar. Truncates in the MIDDLE because these are mostly paths, and the tail
            // (the file name) is the half worth reading.
            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(details, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let failure = job.error, !failure.isEmpty {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Prefer Stash's human-readable job description; fall back to the current sub-task or the raw status.
    ///
    /// Stash titles every plugin job "Running plugin task: <name>", which wrapped to two lines here and
    /// pushed the real information off the bottom. The prefix carries nothing the panel doesn't already
    /// imply, so it's dropped — the task's own name is the title.
    private func title(_ job: JobInfo) -> String {
        var text = job.description
        if text.isEmpty { text = job.subTasks?.first(where: { !$0.isEmpty }) ?? "" }
        if text.isEmpty { return job.status.capitalized }
        let boilerplate = "Running plugin task: "
        if text.hasPrefix(boilerplate) { text.removeFirst(boilerplate.count) }
        return text
    }

    /// Up to two live sub-tasks. Stash can have several units in flight at once (its generate task queue
    /// is concurrent), and the panel is a glance, not a log — two lines say what's happening without the
    /// popover growing every time the server gets busy.
    private func subTasks(_ job: JobInfo) -> [String] {
        let lines = (job.subTasks ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Dedup: two workers on the same kind of task can report identical strings, and `id: \.self`
        // needs unique ids anyway.
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }.prefix(2).map { $0 }
    }

    /// The meta line under the bar: percentage · elapsed · what's waiting behind. Each part is dropped
    /// when Stash doesn't report it, so the line never claims something it doesn't know.
    private func metaLine(_ job: JobInfo) -> String {
        var parts: [String] = []
        if let p = monitor.progress { parts.append("\(Int((p * 100).rounded()))%") }
        if let running = Self.elapsed(since: job.startTime) { parts.append(running) }
        if monitor.queuedCount > 0 { parts.append("+\(monitor.queuedCount) queued") }
        return parts.joined(separator: " · ")
    }

    /// How long the job has been running, from Stash's `startTime`. Recomputed on every poll, so it ticks
    /// without a timer of its own.
    private static func elapsed(since start: String?) -> String? {
        guard let start, let began = parseTimestamp(start) else { return nil }
        let seconds = Int(Date().timeIntervalSince(began))
        guard seconds >= 0 else { return nil }   // clock skew between phone and server — say nothing
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%dm %02ds", minutes, seconds % 60) }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// Stash marshals its `Time` scalar as RFC3339 with a Go-length fractional part (up to 9 digits), and
    /// `ISO8601DateFormatter` only accepts exactly 3 — so on a miss, strip the fraction entirely and retry
    /// (second precision is all an elapsed readout needs). Returns nil rather than guessing: an absent
    /// elapsed reading is fine, a wrong one is not. Formatters are built per call, as elsewhere in the app
    /// — they're not `Sendable`, and this runs at most once per 1.5 s poll while the panel is open.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }

        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let afterDot = raw[raw.index(after: dot)...]
        guard let zoneStart = afterDot.firstIndex(where: { !$0.isNumber }) else { return nil }
        return plain.date(from: String(raw[raw.startIndex..<dot]) + String(afterDot[zoneStart...]))
    }

    // MARK: Actions (Scenes only)

    /// A task chip: icon + name centred in a solid capsule that FILLS its grid column, so every chip is the
    /// same width and the block reads as one tidy set of buttons. Solid fill, never glass — the panel
    /// itself is glass, and glass-on-glass reads flat. Matches the filter panel's tag-chip look.
    ///
    /// Equal columns bought room for `.caption` over the old `.caption2`; `minimumScaleFactor` is the
    /// insurance so a large Dynamic Type setting shrinks "ThumbHash Map" rather than wrapping it.
    private func taskChip(_ title: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(themeManager.current.foregroundColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(themeManager.current.foregroundColor.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
