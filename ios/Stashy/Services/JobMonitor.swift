import Foundation

/// Watches Stash's job queue for the jobs panel: the currently-running job (with live progress) and how many
/// are queued behind it. **Polls only while `start()`-ed** (i.e. while a panel is open) and stops on `stop()`,
/// so nothing runs in the background when the panel isn't visible — the owner's performance requirement.
///
/// Shared singleton because the job queue is global (the Scenes panel and the Performers panel show the same
/// thing); `start()` is idempotent, and only one panel is ever open at a time.
@MainActor
@Observable
final class JobMonitor {
    static let shared = JobMonitor()
    private init() {}

    /// The job Stash is currently running (RUNNING or STOPPING), or nil when idle.
    private(set) var running: JobInfo?
    /// Jobs waiting behind the running one (READY).
    private(set) var queued: [JobInfo] = []

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var client: StashClient?

    var queuedCount: Int { queued.count }
    var isIdle: Bool { running == nil && queued.isEmpty }

    /// Live 0…1 progress of the running job, or nil when indeterminate / idle.
    var progress: Double? {
        guard let p = running?.progress, p >= 0 else { return nil }
        return min(1, p)
    }

    // MARK: Lifecycle (driven by the panel's appear/disappear)

    /// Begin polling the queue. Call when the panel opens. Idempotent.
    func start(client: StashClient) {
        self.client = client
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.loop() }
    }

    /// Stop polling. Call when the panel closes. The last snapshot is kept so a reopen shows instantly.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loop() async {
        var fails = 0
        while !Task.isCancelled {
            if let client {
                do {
                    apply(try await client.jobQueue())
                    fails = 0
                } catch {
                    fails += 1   // transient blip (Stash busy / DB locked) — keep polling, don't reset state
                    if fails > 40 { stop(); return }   // ~60s of failures → give up until the panel reopens
                }
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    private func apply(_ jobs: [JobInfo]) {
        running = jobs.first { $0.status == "RUNNING" || $0.status == "STOPPING" }
        queued = jobs.filter { $0.status == "READY" }
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
        _ = try? await client.metadataScan()
        await refreshNow()
    }

    /// Queue a Companion plugin map-compute task (VMAF / ThumbHash / Loudness).
    func runCompanionTask(_ task: StashCompanion.Task) async {
        guard let client else { return }
        _ = try? await StashCompanion(client: client).run(task, args: [:])
        await refreshNow()
    }
}
