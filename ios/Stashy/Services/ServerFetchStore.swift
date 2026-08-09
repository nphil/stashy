import Foundation

/// The app-side ledger of SERVER-side URL fetches (companion plugin ≥0.5.0, "Fetch URL to Library").
///
/// Each submission is one Stash job on the server plus one persisted card here. Live detail the job
/// API can't carry (bytes / total / speed / ETA / filename) rides the plugin's served
/// `cache/fetch-status.json`, keyed by the app-generated `fetchID` — so the Downloads screen shows
/// real transfer telemetry, live-synced to the server.
///
/// Control verbs, and what they really are:
///  * pause  = `stopJob`. The plugin's yt-dlp child dies with it (PDEATHSIG) and the `.part` STAYS.
///  * resume = resubmit the same fetchID + URL — yt-dlp continues the `.part` byte-exact.
///  * cancel = `stopJob` + server-side delete of the partial + card removed.
///  * remove = drop the finished/failed card (the finished FILE is library content now — deleting
///    library media is the library's business, not a download card's).
///
/// Polling runs ONLY while the Downloads screen is visible, at 1 Hz, and follows the house rule: a
/// poll behind visible UI never self-terminates — transient errors back off and keep trying.
@MainActor @Observable
final class ServerFetchStore {
    static let shared = ServerFetchStore()
    private init() { load() }

    // MARK: - Model

    enum Phase: String, Codable, Sendable {
        case queued        // job submitted; Stash hasn't started it (its job queue is serial)
        case running
        case paused        // stopJob'd with the partial kept — resumable
        case done          // downloaded + scan queued; the scene appears when the scan finishes
        case failed
    }

    struct Item: Identifiable, Codable, Equatable, Sendable {
        let id: String                 // fetchID (app-generated UUID) — keys the served status entry
        var url: String
        var jobID: String?
        var submittedAt: Date
        var phase: Phase
        /// Resolver captures, retained so RESUME can replay them. Cookies can expire between pause
        /// and resume; yt-dlp re-extracts where it can, and a failed resume shows as failed.
        var headers: [String: String]?
        var filenameHint: String?
        // Live telemetry from the served status file (nil until the server reports).
        var filename: String?
        var downloaded: Int64?
        var total: Int64?
        var speed: Int64?
        var eta: Int?
        var error: String?

        /// What the card titles itself: real filename once known, else the hint, else the host.
        var displayName: String {
            if let filename, !filename.isEmpty { return filename }
            if let filenameHint, !filenameHint.isEmpty { return filenameHint }
            return URL(string: url)?.host() ?? url
        }
    }

    private(set) var items: [Item] = []
    var hasItems: Bool { !items.isEmpty }

    // MARK: - Wiring

    @ObservationIgnored private var client: StashClient?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var visible = false

    private var companion: StashCompanion? { client.map(StashCompanion.init(client:)) }

    func configure(client: StashClient?) {
        self.client = client
    }

    /// Downloads-screen visibility gates the poll loop (1 Hz is pointless with nobody looking; the
    /// server job runs regardless and cards refresh the moment the screen returns).
    func setVisible(_ nowVisible: Bool) {
        visible = nowVisible
        if nowVisible { startPolling() } else { pollTask?.cancel(); pollTask = nil }
    }

    // MARK: - Verbs

    /// Queue a server fetch. Multiple submissions queue naturally — Stash runs its jobs serially.
    func submit(url: String, headers: [String: String]? = nil, filenameHint: String? = nil) async throws {
        guard let companion else { throw StashError.graphqlError("not connected") }
        let fetchID = UUID().uuidString.lowercased()
        var item = Item(id: fetchID, url: url, jobID: nil, submittedAt: Date(), phase: .queued,
                        headers: headers, filenameHint: filenameHint)
        let jobID = try await companion.requestFetch(url: url, fetchID: fetchID,
                                                    headers: headers, filename: filenameHint)
        item.jobID = jobID
        items.insert(item, at: 0)
        save()
        startPolling()
    }

    /// Stop the server job, keep the partial. Resume continues it byte-exact.
    func pause(_ id: String) async {
        guard let companion, let jobID = items.first(where: { $0.id == id })?.jobID else { return }
        _ = try? await companion.stopJob(jobID)
        // Re-resolve AFTER the await: MainActor reentrancy means the array can change under a
        // suspension (a cancel tap mid-request), so a pre-await index is a trap waiting to fire.
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].phase = .paused
        items[idx].speed = nil
        items[idx].eta = nil
        save()
    }

    /// Resubmit — same fetchID, same URL, same captured headers → the plugin reuses the status entry
    /// and yt-dlp continues the .part.
    func resume(_ id: String) async {
        guard let companion, let item = items.first(where: { $0.id == id }) else { return }
        do {
            let jobID = try await companion.requestFetch(url: item.url, fetchID: item.id,
                                                         headers: item.headers,
                                                         filename: item.filenameHint)
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }   // re-resolve post-await
            items[idx].jobID = jobID
            items[idx].phase = .queued
            items[idx].error = nil
            save()
            startPolling()
        } catch {
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].phase = .failed
            items[idx].error = "Couldn't resume: \(error.localizedDescription)"
            save()
        }
    }

    /// Stop (if running), delete the server-side partial, drop the card.
    func cancel(_ id: String) async {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]
        if let companion {
            if let jobID = item.jobID, item.phase == .running || item.phase == .queued {
                _ = try? await companion.stopJob(jobID)
            }
            try? await companion.deleteFetched(fetchID: item.id, filename: item.filename)
        }
        items.removeAll { $0.id == id }
        save()
    }

    /// Drop a terminal card. The fetched FILE stays — it's library content now.
    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
        Task { [companion] in try? await companion?.deleteStatusEntry(fetchID: id) }
    }

    /// Failed card → try again from scratch (or from the .part, if one survived).
    func retry(_ id: String) async {
        await resume(id)
    }

    // MARK: - Polling

    private var needsPolling: Bool {
        items.contains { $0.phase == .queued || $0.phase == .running }
    }

    private func startPolling() {
        guard visible, needsPolling, pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                guard self.visible else { return }
                if !self.needsPolling {
                    // Idle wait — cheap, and a new submit() calls startPolling() anyway.
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let ok = await self.pollOnce()
                backoff = ok ? 1 : min(10, backoff * 1.7)
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
    }

    /// One sweep: job statuses first (authoritative for phase), then the served status file for
    /// telemetry. Returns false on transport trouble so the loop backs off — but NEVER stops.
    private func pollOnce() async -> Bool {
        guard let companion, let client else { return false }
        var healthy = true
        let before = items

        // Sweep by ID, never by index: every job() call is a suspension, and MainActor reentrancy
        // means a cancel tap can shrink `items` mid-sweep — a captured index would trap or hit the
        // wrong card. Re-resolve after each await.
        for id in items.filter({ $0.phase == .queued || $0.phase == .running }).map(\.id) {
            guard let jobID = items.first(where: { $0.id == id })?.jobID else { continue }
            do {
                let job = try await companion.job(jobID)
                guard let idx = items.firstIndex(where: { $0.id == id }) else { continue }
                switch job.status {
                case "RUNNING", "STOPPING":
                    items[idx].phase = .running
                case "FINISHED":
                    items[idx].phase = .done
                    items[idx].speed = nil
                    items[idx].eta = nil
                case "FAILED":
                    items[idx].phase = .failed
                    items[idx].error = (job.error?.isEmpty == false) ? job.error : "The server job failed."
                case "CANCELLED":
                    items[idx].phase = .paused    // stopJob'd (maybe from Stash's UI) — resumable
                default:
                    items[idx].phase = .queued    // READY — waiting in Stash's serial queue
                }
            } catch {
                // "job not found" after Stash GC'd a finished queue is terminal-ish, but we cannot
                // distinguish it from transport failure reliably — the served status file resolves
                // it below when it says "done". Until then: back off, keep trying (house rule).
                healthy = false
            }
        }

        if let statuses = await fetchServedStatus(client: client) {
            for idx in items.indices {
                guard let entry = statuses[items[idx].id] else { continue }
                items[idx].filename = entry.filename ?? items[idx].filename
                items[idx].downloaded = entry.downloaded ?? items[idx].downloaded
                items[idx].total = entry.total ?? items[idx].total
                if items[idx].phase == .running {
                    items[idx].speed = entry.speed
                    items[idx].eta = entry.eta
                }
                if entry.status == "done", items[idx].phase == .queued || items[idx].phase == .running {
                    // Covers the GC'd-job hole: the plugin's own record says it finished.
                    items[idx].phase = .done
                }
                if entry.status == "failed", items[idx].phase == .running || items[idx].phase == .queued {
                    items[idx].phase = .failed
                    items[idx].error = entry.error ?? items[idx].error
                }
            }
        }
        if items != before { save() }   // ~1 Hz of identical UserDefaults writes is pointless churn
        return healthy
    }

    private struct StatusEntry: Decodable, Sendable {
        var status: String?
        var filename: String?
        var downloaded: Int64?
        var total: Int64?
        var speed: Int64?
        var eta: Int?
        var error: String?
    }
    private struct StatusPayload: Decodable, Sendable { let entries: [String: StatusEntry] }

    /// The plugin's served live-status file — same fetch shape as LoudnessStore's served JSON.
    private func fetchServedStatus(client: StashClient) async -> [String: StatusEntry]? {
        guard var comps = URLComponents(
            string: "\(client.serverURL)/plugin/\(StashCompanion.pluginID)/assets/cache/fetch-status.json")
        else { return nil }
        if !client.apiKey.isEmpty { comps.queryItems = [URLQueryItem(name: "apikey", value: client.apiKey)] }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(StatusPayload.self, from: data))?.entries
    }

    // MARK: - Persistence (survives relaunch; the server job runs regardless)

    private static let storeKey = "serverFetches"

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return }
        // A relaunch mid-download: phases refresh on the first poll; running looks queued until then.
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

extension StashCompanion {
    /// Remove just the served status entry for a card (FILE UNTOUCHED — `entry_only` is what stops
    /// the plugin resolving the recorded filename and deleting library content). Best-effort.
    func deleteStatusEntry(fetchID: String) async throws {
        _ = try await run(.fetchDelete, args: ["fetch_id": fetchID, "entry_only": "1"])
    }
}
