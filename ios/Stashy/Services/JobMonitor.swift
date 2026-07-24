import Foundation

/// Watches Stash's job queue for the jobs panel: the currently-running job (with live progress) and how many
/// are queued behind it. **Polls only while a panel is attached** (i.e. while a dropdown is open) and stops
/// when the last panel detaches, so nothing runs in the background — the owner's performance requirement.
///
/// Robustness rules (from the scan-progress-bar bug, 2026-07-24):
///  • An EMPTY queue is a *successful* poll: Stash's nullable `jobQueue` returns `null` for it, which
///    `StashClient.jobQueue()` maps to `[]`. (Treating it as an error froze the last snapshot on screen.)
///  • The loop NEVER kills itself. Sustained failures flip `pollFailing` (the panel shows a retry line),
///    clear the stale snapshot — a frozen progress bar reads as a stuck job — and keep polling at a slower
///    cadence until the panel closes.
///  • Attach/detach is REFCOUNTED: on a rapid close→reopen SwiftUI can deliver the dying panel instance's
///    `onDisappear` *after* the replacement's `onAppear`; a naive start/stop pair let that late stop
///    silently kill polling for the panel still on screen (progress bar never appeared).
///  • Queuing a task gives instant optimistic feedback (`starting`) and surfaces failures (`actionError`)
///    instead of `try?`-swallowing them.
///
/// Shared singleton because the job queue is global (the Scenes panel and the Performers panel show the same
/// thing); only one panel is ever open at a time, but the refcount tolerates overlap.
@MainActor
@Observable
final class JobMonitor {
    static let shared = JobMonitor()
    private init() {}

    /// The job Stash is currently running (RUNNING or STOPPING), or nil when idle.
    private(set) var running: JobInfo?
    /// Jobs waiting behind the running one (READY).
    private(set) var queued: [JobInfo] = []
    /// True once several consecutive polls have failed. The panel shows a reconnecting line instead of a
    /// stale snapshot; cleared by the next successful poll.
    private(set) var pollFailing = false
    /// Title of a task the user just queued, shown until it materialises in a poll (or a short grace
    /// window elapses — e.g. a scan that finished between two ticks).
    private(set) var starting: String?
    /// Why the last queue-a-task action failed (plugin missing / auth / network) — shown in the panel.
    private(set) var actionError: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var client: StashClient?
    @ObservationIgnored private var attachCount = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var startingGrace = 0

    var queuedCount: Int { queued.count }

    /// Live 0…1 progress of the running job, or nil when indeterminate / idle.
    var progress: Double? {
        guard let p = running?.progress, p >= 0 else { return nil }
        return min(1, p)
    }

    // MARK: Lifecycle (driven by the panel's appear/disappear)

    /// Begin polling the queue. Call from the panel's `onAppear`; balanced by `detach()`.
    func attach(client: StashClient) {
        self.client = client
        attachCount += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.loop() }
    }

    /// Balance one `attach`. The last detach stops polling; the snapshot is kept so a reopen shows instantly.
    func detach() {
        attachCount = max(0, attachCount - 1)
        guard attachCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            if let client {
                do {
                    apply(try await client.jobQueue())
                } catch {
                    if Task.isCancelled { break }   // detach mid-request — not a server failure
                    pollFailed()
                }
            }
            // Back off while unreachable, but never stop: the loop only exists while a panel is open, and
            // a loop that gave up silently is exactly what left the old panel frozen mid-scan.
            try? await Task.sleep(for: .milliseconds(pollFailing ? 4000 : 1500))
        }
    }

    private func apply(_ jobs: [JobInfo]) {
        failures = 0
        pollFailing = false
        running = jobs.first { $0.status == "RUNNING" || $0.status == "STOPPING" }
        queued = jobs.filter { $0.status == "READY" }
        // Retire the optimistic "Starting…" once the real queue reflects the tap — or after the grace
        // window, which covers a task that finished before the next tick even saw it.
        if starting != nil {
            if running != nil || !queued.isEmpty {
                starting = nil
            } else {
                startingGrace -= 1
                if startingGrace <= 0 { starting = nil }
            }
        }
    }

    private func pollFailed() {
        failures += 1
        guard failures >= 3 else { return }   // ride out a 1–2 tick blip (Stash busy) without any flicker
        pollFailing = true
        // Don't keep painting a snapshot we can't update — a frozen bar reads as a stuck job.
        running = nil
        queued = []
        starting = nil
    }

    /// Refresh once immediately — after queuing a task, so it appears without waiting for the next tick.
    func refreshNow() async {
        guard let client, let jobs = try? await client.jobQueue() else { return }
        apply(jobs)
    }

    // MARK: Actions (the panel's buttons)

    /// Queue Stash's native library scan (server defaults).
    func scanLibrary() async {
        guard let client else { return }
        actionError = nil
        do {
            _ = try await client.metadataScan()
            noteQueued("library scan")
        } catch {
            actionError = Self.message(error)
        }
        await refreshNow()
    }

    /// Queue a Companion plugin map-compute task (VMAF / ThumbHash / Loudness). `title` is the short
    /// human-readable name for the optimistic "Starting…" line.
    func runCompanionTask(_ task: StashCompanion.Task, title: String) async {
        guard let client else { return }
        actionError = nil
        do {
            _ = try await StashCompanion(client: client).run(task, args: [:])
            noteQueued(title)
        } catch {
            actionError = Self.message(error)
        }
        await refreshNow()
    }

    /// Cancel the currently-running job (the panel's stop button). Optimistically drops it from the snapshot
    /// so the UI updates instantly, then refreshes from the server (it becomes STOPPING → CANCELLED).
    func cancelRunningJob() async {
        guard let client, let job = running else { return }
        running = nil
        _ = try? await client.stopJob(id: job.id)
        await refreshNow()
    }

    private func noteQueued(_ title: String) {
        starting = title
        startingGrace = 3
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
