import Foundation
import UIKit

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
/// Polling follows INTENT, not the screen: it runs while any fetch is queued or running — 1 Hz with the
/// Downloads screen up and the app active, every 3 s otherwise (another tab, minimised, locked) — so the
/// Lock Screen / Dynamic Island card has real numbers with nobody looking. House rule: a poll never
/// self-terminates while intent remains — transient errors back off (capped at 10 s) and keep trying;
/// it stops only when nothing is queued or running, and `submit` / `resume` / a relaunch / `setVisible`
/// start it again. `confirmedAt` records what the server has vouched for THIS session, which is what
/// gates the card and the background keep-alive (never the persisted phase).
@MainActor @Observable
final class ServerFetchStore {
    static let shared = ServerFetchStore()
    private init() {
        load()
        // A fetch restored mid-run keeps being tracked (and its card re-earned) without Downloads
        // ever being opened this launch.
        startPolling()
    }

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

    /// Fires when a fetch is queued, paused, resumed, removed, or changes phase — deliberately NOT on
    /// every telemetry tick (the card's own 2 s loop carries those). `DownloadManager` hooks it in
    /// `init` to start or end the Lock Screen card at once, and to hold the process alive for a fetch
    /// that becomes live while the app is already minimised.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    /// When the SERVER last vouched for each fetch (its job was queued/running, or the request that
    /// created it was accepted). In memory only, on purpose: a persisted phase can't be trusted after
    /// a relaunch — it can describe a fetch that finished while the app was dead — so nothing counts
    /// as live work, or earns a card, until the server confirms it again this session. A key here
    /// also means "this session owns it" (like `DownloadManager.activityOwned`): only owned fetches
    /// may show as paused/failed on the card, so last week's failure never resurrects one.
    @ObservationIgnored private var confirmedAt: [String: Date] = [:]
    @ObservationIgnored private var lastReachable: Bool?

    /// Longer than one slow poll cycle (10 s backoff cap + a status fetch), so a single dropped poll
    /// doesn't flicker the card to "can't reach".
    private static let confirmWindow: TimeInterval = 45

    /// How much longer the background keep-alive holds than the card trusts the numbers. At
    /// `confirmWindow` the card says "Can't reach your server", and the process must still be awake for
    /// the 2 s sync that pushes that line — so the pump may not let go in the same breath. The sum
    /// (~1 min) is also the most a dead server can keep the app awake: the battery bound.
    private static let keepAliveGrace: TimeInterval = 15

    /// The Downloads screen hands over its client, but a fetch must keep being tracked when that screen
    /// was never opened this launch (the Lock Screen card is the point), so fall back to the saved
    /// login — the same Keychain pair `DownloadManager` builds its companion calls from. Read per use,
    /// not cached: a disconnect clears the Keychain and tracking should stop with it. (The items are
    /// `WhenUnlocked`, so a locked relaunch just finds no client and tries again next sweep.)
    private var activeClient: StashClient? {
        if let client { return client }
        guard let url = KeychainService.read("serverURL"), !url.isEmpty else { return nil }
        return StashClient(serverURL: url, apiKey: KeychainService.read("apiKey") ?? "")
    }

    private var companion: StashCompanion? { activeClient.map(StashCompanion.init(client:)) }

    func configure(client: StashClient?) {
        self.client = client
    }

    /// Downloads-screen visibility only picks the poll CADENCE (1 Hz with the screen up, slower
    /// otherwise — see `pollInterval`); it never decides whether the poll runs. Restarting the loop
    /// makes a new cadence take effect now rather than after the old sleep.
    func setVisible(_ nowVisible: Bool) {
        if visible != nowVisible {
            visible = nowVisible
            pollTask?.cancel()
            pollTask = nil
        }
        startPolling()
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
        confirmedAt[fetchID] = Date()    // the server just accepted it, and this session started it
        save()
        startPolling()
        onChange?()
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
        onChange?()
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
            confirmedAt[id] = Date()     // accepted just now; this session owns it
            save()
            startPolling()
            onChange?()
        } catch {
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].phase = .failed
            items[idx].error = "Couldn't resume: \(error.localizedDescription)"
            save()
            onChange?()
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
        pruneConfirmations()
        save()
        onChange?()
    }

    /// Drop a terminal card. The fetched FILE stays — it's library content now.
    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        pruneConfirmations()
        save()
        onChange?()
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

    /// 1 Hz when somebody is looking (Downloads on screen, app active), every 3 s otherwise — enough
    /// to keep the Lock Screen card moving with the app minimised, gentle on the battery and the server.
    private var pollInterval: Double {
        visible && UIApplication.shared.applicationState == .active ? 1 : 3
    }

    /// The loop's ONLY off-switch is `needsPolling` going false — the loss of intent (nothing is
    /// queued or running any more). It never depends on the screen: the card needs these numbers with
    /// nobody looking. Everything that can create intent again calls this — `submit`, `resume`, a
    /// relaunch (`init`), the screen appearing (`setVisible`).
    private func startPolling() {
        guard needsPolling, pollTask == nil else { return }
        trace("dl-fetch", [("poll", "start"), ("visible", visible), ("fetches", items.count)])
        pollTask = Task { @MainActor [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                // Checked and cleared in one main-actor turn, so a submit() can't land between the two
                // and find a dead loop it believes is alive.
                guard self.needsPolling else {
                    self.pollTask = nil
                    self.trace("dl-fetch", [("poll", "stop")])
                    return
                }
                let ok = await self.pollOnce()
                let base = self.pollInterval
                backoff = ok ? 1 : min(10, backoff * 1.7)
                try? await Task.sleep(for: .seconds(ok ? base : max(base, backoff)))
            }
        }
    }

    /// One sweep: job statuses first (authoritative for phase), then the served status file for
    /// telemetry. Returns false on transport trouble so the loop backs off — but NEVER stops.
    private func pollOnce() async -> Bool {
        guard let client = activeClient else { return false }
        let companion = StashCompanion(client: client)
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
                    confirmedAt[id] = Date()
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
                    confirmedAt[id] = Date()
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
        pruneConfirmations()
        noteReachability()
        if items != before { save() }   // ~1 Hz of identical UserDefaults writes is pointless churn
        if items.map(\.phase) != before.map(\.phase) { onChange?() }
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

    // MARK: - Lock Screen card + keep-alive

    /// A fetch the Lock Screen card should describe, and whether its numbers can still be trusted.
    struct CardFetch {
        let item: Item
        /// False once the server hasn't vouched for it within `confirmWindow` — the card then says it
        /// can't reach the server rather than keep showing a speed and ETA that may no longer exist.
        let reachable: Bool
    }

    /// The fetches that belong on the card right now. Only fetches the server confirmed THIS session
    /// qualify (see `confirmedAt`): `live` are queued/running — running first, then oldest first (the
    /// order Stash's serial queue runs them) — and `halted` are the paused/failed ones this session
    /// started, newest first. A finished fetch has nothing left to show and drops out, which is what
    /// ends the card.
    func cardFetches(now: Date = .now) -> (live: [CardFetch], halted: [Item]) {
        var live: [CardFetch] = []
        var halted: [Item] = []
        for item in items {
            guard let seen = confirmedAt[item.id] else { continue }
            switch item.phase {
            case .queued, .running:
                live.append(CardFetch(item: item,
                                      reachable: now.timeIntervalSince(seen) <= Self.confirmWindow))
            case .paused, .failed:
                halted.append(item)
            case .done:
                break
            }
        }
        live.sort {
            if ($0.item.phase == .running) != ($1.item.phase == .running) { return $0.item.phase == .running }
            return $0.item.submittedAt < $1.item.submittedAt
        }
        return (live, halted)
    }

    /// True while the server has vouched for a queued/running fetch within `confirmWindow` +
    /// `keepAliveGrace`. This — never the persisted phase — is what lets `DownloadManager` hold the
    /// process alive in the background: a relaunch restores `.running` for fetches that finished while
    /// the app was dead, and an unreachable server never refreshes them, so counting persisted phases
    /// would pump forever.
    var hasLiveWork: Bool {
        // Judge it `keepAliveGrace` earlier than the card does (see there).
        cardFetches(now: Date.now.addingTimeInterval(-Self.keepAliveGrace)).live.contains { $0.reachable }
    }

    /// An id leaves the ledger when its fetch is gone or finished.
    private func pruneConfirmations() {
        let keep = Set(items.filter { $0.phase != .done }.map(\.id))
        confirmedAt = confirmedAt.filter { keep.contains($0.key) }
    }

    /// Log the moment tracking loses or regains the server, so a "card said can't reach" report can
    /// be matched to the poll that caused it.
    private func noteReachability() {
        let live = cardFetches().live
        guard !live.isEmpty else { lastReachable = nil; return }
        let reachable = live.contains { $0.reachable }
        guard reachable != lastReachable else { return }
        lastReachable = reachable
        trace("dl-fetch", [("reach", reachable ? 1 : 0), ("live", live.count)])
    }

    private func trace(_ tag: String, _ fields: [(String, Any?)]) {
        RemoteLog.shared.event(tag, fields)
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
