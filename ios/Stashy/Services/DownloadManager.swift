import SwiftUI
import UIKit
import Network
import Observation

/// Process-wide handoff for the background `URLSession`. iOS relaunches the app (possibly straight into
/// the background) when queued transfers finish while it was suspended, handing the app delegate a
/// completion handler that must be called once the session has drained its events — see
/// `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` and
/// `DownloadDelegate.urlSessionDidFinishEvents`.
enum BackgroundDownloadSession {
    static let identifier = "com.nphil.stashy.downloads"
    /// Set on the main thread by the app delegate; called (and cleared) on the main thread once the
    /// session reports it has delivered every queued event. `nonisolated(unsafe)` because it is only ever
    /// touched on the main thread.
    nonisolated(unsafe) static var completionHandler: (() -> Void)?
}

/// Ferries a non-Sendable value across a concurrency boundary when the caller guarantees the access is
/// safe (e.g. `URLSessionTask`s whose only cross-thread use is reading identifiers / calling `cancel`).
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Lifecycle of a download. `waitingForNetwork` is an automatic pause (connectivity lost) distinct from
/// a user `paused`; `stopped` items are pruned when the Downloads screen is re-entered.
enum DownloadState: Equatable {
    case queued, downloading, paused, waitingForNetwork, merging, completed, failed, stopped
}

/// One parallel connection (byte-range) of a multi-connection download, drawn as its own coloured
/// segment on the card.
struct DownloadConnection: Identifiable {
    let id: Int
    let color: Color
    var received: Int64 = 0
    var total: Int64
    var progress: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    static let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .red]
}

@Observable
@MainActor
final class DownloadItem: Identifiable {
    let id: String
    let title: String
    let url: URL
    let fileName: String
    // Spec fields are var so an on-device transcode can update them in place once it rewrites the file.
    var ext: String
    var codec: String?
    var width: Int?
    var height: Int?
    var bitRate: Int?
    var totalBytes: Int64
    /// Source scene (for the card thumbnail/performer and tap-to-play). Persisted in a sidecar so it
    /// survives relaunch. `var` so an on-device transcode can update the media specs in place (and rewrite
    /// the sidecar), keeping the detail view / stats in sync with the transcoded file.
    var scene: StashScene?
    let apiKey: String
    /// Local thumbnail file downloaded alongside the video, so the card shows imagery offline.
    var localThumb: URL?

    var thumbnailURL: URL? { scene?.thumbnailURL(apiKey: apiKey) }
    var performerImageURL: URL? { scene?.performers.first?.imageURL(apiKey: apiKey) }
    var performerName: String? { scene?.performers.first?.name }

    var state: DownloadState = .queued
    var connections: [DownloadConnection]
    var receivedBytes: Int64 = 0
    var speed: Double = 0            // bytes/sec, smoothed by the poll loop
    var error: String?
    var localURL: URL?

    /// On-device transcode progress (0…1) while `transcoding`; the card shows it in place of the download bar.
    var transcoding = false
    var transcodeProgress: Double = 0
    /// Compact target label ("HEVC 1080p") shown live during a transcode; nil when not transcoding.
    var transcodeTargetLabel: String?
    /// Live diagnostic event log shown in a box on the card while/after transcoding (decoder hw/sw,
    /// encoder, audio, done). Append-only distinct lines. Cleared when a transcode starts, and wiped when
    /// the user leaves the Downloads screen and returns.
    var transcodeLog: String = ""
    /// The single live status line (fps · frame · %), updated in place under the event log so it doesn't
    /// flood the box with a new line every tick.
    var transcodeStatus: String = ""
    /// True once a completed download has been transcoded on-device, so the card can badge it "Transcoded".
    /// In-memory only (not in the sidecar), so it resets on relaunch — the transcoded specs themselves DO
    /// persist via the rewritten sidecar.
    var wasTranscoded = false

    @ObservationIgnored var lastSampleBytes: Int64 = 0
    @ObservationIgnored var lastSampleTime = Date()

    var progress: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }

    var resolutionLabel: String? { height.map { "\($0)p" } }
    var codecLabel: String? { codec?.uppercased() }
    var bitrateLabel: String? {
        // Prefer the stored bitrate; fall back to size÷duration so files transcoded before the bitrate was
        // recomputed (or any item missing it) still show one.
        var bps = bitRate.map(Double.init) ?? 0
        if bps <= 0, let dur = scene?.files.first?.duration, dur > 0, totalBytes > 0 {
            bps = Double(totalBytes) * 8 / dur
        }
        guard bps > 0 else { return nil }
        return String(format: "%.1f Mbps", bps / 1_000_000)
    }
    var sizeLabel: String? {
        guard totalBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
    var speedLabel: String {
        guard speed > 0, state == .downloading else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }
    var etaLabel: String {
        guard speed > 100, totalBytes > receivedBytes, state == .downloading else { return "" }
        let secs = Double(totalBytes - receivedBytes) / speed
        let m = Int(secs) / 60, s = Int(secs) % 60
        return m > 0 ? "\(m)m \(s)s left" : "\(s)s left"
    }

    init(id: String, title: String, url: URL, fileName: String, ext: String,
         codec: String?, width: Int?, height: Int?, bitRate: Int?, totalBytes: Int64, connectionCount: Int,
         scene: StashScene? = nil, apiKey: String = "", localThumb: URL? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.fileName = fileName
        self.ext = ext
        self.codec = codec
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.totalBytes = totalBytes
        self.scene = scene
        self.apiKey = apiKey
        self.localThumb = localThumb
        let n = max(1, connectionCount)
        let chunk = totalBytes / Int64(n)
        self.connections = (0..<n).map { i in
            let isLast = i == n - 1
            let total = totalBytes > 0 ? (isLast ? totalBytes - chunk * Int64(n - 1) : chunk) : 0
            return DownloadConnection(id: i, color: DownloadConnection.palette[i % DownloadConnection.palette.count], total: total)
        }
    }
}

/// Cross-thread transfer bookkeeping, touched from the (background) URLSession delegate queue and the
/// main-actor poll loop, so it lives behind a lock rather than on the actor.
private final class TransferStore: @unchecked Sendable {
    private let lock = NSLock()
    private var info: [Int: (item: String, conn: Int, part: URL)] = [:]
    private var received: [Int: Int64] = [:]

    func register(task: Int, item: String, conn: Int, part: URL) {
        lock.lock(); defer { lock.unlock() }
        info[task] = (item, conn, part); received[task] = 0
    }
    func setReceived(task: Int, _ bytes: Int64) { lock.lock(); received[task] = bytes; lock.unlock() }
    func info(task: Int) -> (item: String, conn: Int, part: URL)? { lock.lock(); defer { lock.unlock() }; return info[task] }
    func drop(task: Int) { lock.lock(); info[task] = nil; received[task] = nil; lock.unlock() }
    func snapshot() -> (info: [Int: (item: String, conn: Int, part: URL)], received: [Int: Int64]) {
        lock.lock(); defer { lock.unlock() }; return (info, received)
    }
}

/// URLSession delegate kept separate from the (observable, main-actor) manager: its callbacks arrive on
/// a background queue, do the synchronous part-file move there, and forward structural events to the
/// manager on the main actor via `@Sendable` closures. High-frequency progress goes straight to the
/// lock-guarded store (the manager polls it), so it never hops the actor per byte.
///
/// A task's identity (item id, connection, part path) is also encoded in its `taskDescription`, so after
/// the app is relaunched to finish a background transfer — when the in-memory store is empty — the
/// delegate can still route the finished file to the right part and item.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let store: TransferStore
    let onFinish: @Sendable (String, Int) -> Void
    let onError: @Sendable (String, String, Int) -> Void

    init(store: TransferStore,
         onFinish: @escaping @Sendable (String, Int) -> Void,
         onError: @escaping @Sendable (String, String, Int) -> Void) {
        self.store = store
        self.onFinish = onFinish
        self.onError = onError
    }

    /// Task → (item, conn, part), from the live store or, after a cold background relaunch, decoded from
    /// the task's persisted `taskDescription` ("<itemID>\u{1}<conn>\u{1}<partPath>").
    private func info(for task: URLSessionTask) -> (item: String, conn: Int, part: URL)? {
        if let live = store.info(task: task.taskIdentifier) { return live }
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.components(separatedBy: "\u{1}")
        guard parts.count == 3, let conn = Int(parts[1]) else { return nil }
        return (parts[0], conn, URL(fileURLWithPath: parts[2]))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        store.setReceived(task: downloadTask.taskIdentifier, totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = info(for: downloadTask) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: info.part)
        try? fm.moveItem(at: location, to: info.part)
        store.drop(task: downloadTask.taskIdentifier)
        onFinish(info.item, info.conn)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }                            // success handled by didFinishDownloadingTo
        if (error as NSError).code == NSURLErrorCancelled { return }   // pause/stop
        let info = info(for: task)
        store.drop(task: task.taskIdentifier)
        if let info { onError(info.item, error.localizedDescription, (error as NSError).code) }
    }

    /// The background session has delivered every event queued while the app was suspended — release the
    /// system's background-launch completion handler so iOS can suspend us again.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            BackgroundDownloadSession.completionHandler?()
            BackgroundDownloadSession.completionHandler = nil
        }
    }
}

@Observable
@MainActor
final class DownloadManager {
    var items: [DownloadItem] = []

    @ObservationIgnored private let connectionCount = 8
    @ObservationIgnored private let store = TransferStore()
    @ObservationIgnored private var session: URLSession!       // foreground: 8-way parallel
    @ObservationIgnored private var bgSession: URLSession!     // background: one connection at a time
    @ObservationIgnored private var delegate: DownloadDelegate!
    @ObservationIgnored private var tasks: [String: [URLSessionDownloadTask]] = [:]
    @ObservationIgnored private var resumeData: [String: [Int: Data]] = [:]
    @ObservationIgnored private var finished: [String: Set<Int>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Latest connectivity status from the monitor (whether the current path can carry traffic).
    @ObservationIgnored private var pathSatisfied = true
    /// Consecutive transient-network retries per item, so a persistently-unreachable URL eventually fails
    /// instead of retrying forever; reset when the item makes real progress.
    @ObservationIgnored private var networkRetries: [String: Int] = [:]
    private let maxNetworkRetries = 10
    /// True while the app is backgrounded: downloads run one connection at a time on the background session
    /// (surviving suspension) instead of 8-way parallel on the foreground session.
    @ObservationIgnored private var inBackground = false
    /// Outstanding resume-data cancellations per item during a foreground⇄background handoff (we restart on
    /// the other engine only once every task has produced its resume data).
    @ObservationIgnored private var pendingHandoff: [String: Int] = [:]
    /// Keeps the app alive briefly while a background handoff completes and its background task starts.
    @ObservationIgnored private var handoffAssertion: UIBackgroundTaskIdentifier = .invalid

    @ObservationIgnored private let downloadsDir: URL
    @ObservationIgnored private let partsDir: URL
    @ObservationIgnored private let metaDir: URL

    init() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Downloaded media + sidecars live under Application Support (private to the app — never surfaced
        // in the Files app or to other apps, unlike Documents which *can* be exposed via file-sharing), in
        // a Stashy-scoped folder excluded from iCloud/iTunes backup. Parts are transient → Caches.
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stashy", isDirectory: true)
        downloadsDir = base.appendingPathComponent("Downloads", isDirectory: true)
        metaDir = base.appendingPathComponent("DownloadsMeta", isDirectory: true)
        partsDir = caches.appendingPathComponent("DownloadParts", isDirectory: true)
        for dir in [downloadsDir, partsDir, metaDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        Self.excludeFromBackup(base)
        // The legacy Documents store is a one-time migration; after the first run there is nothing left to
        // move, so skip the Documents enumeration on every subsequent launch. The move is best-effort and
        // idempotent (dest-exists guarded), so setting the flag right after the call is safe.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didMigrateLegacyDownloadStore") {
            Self.migrateLegacyStore(from: docs, downloadsDir: downloadsDir, metaDir: metaDir)
            defaults.set(true, forKey: "didMigrateLegacyDownloadStore")
        }

        delegate = DownloadDelegate(
            store: store,
            onFinish: { [weak self] item, conn in Task { @MainActor in self?.connectionFinished(itemID: item, conn: conn) } },
            onError: { [weak self] item, msg, code in Task { @MainActor in self?.connectionFailed(itemID: item, message: msg, code: code) } }
        )
        // Foreground: 8-way parallel range downloads on a default session (fast). Background: a single
        // connection at a time on a background session, so a download keeps going while the app is
        // suspended — without the NSURLErrorCannotCreateFile (-3000) the background daemon returns for
        // *parallel* range (206) tasks. We switch engines on app-phase changes, reusing the same 8 part
        // files either way, so no progress is lost in either direction.
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let bgConfig = URLSessionConfiguration.background(withIdentifier: BackgroundDownloadSession.identifier)
        bgConfig.sessionSendsLaunchEvents = true
        bgConfig.isDiscretionary = false
        bgConfig.waitsForConnectivity = true
        bgSession = URLSession(configuration: bgConfig, delegate: delegate, delegateQueue: nil)

        inBackground = UIApplication.shared.applicationState == .background

        loadCompleted()
        loadInterrupted()      // rebuild in-flight items from sidecars so relaunch callbacks find them
        sweepOrphanedMeta()    // reclaim sidecars left by stopped/abandoned/crashed downloads
        finalizeReadyItems()   // any item whose parts are all present already → assemble now
        reconnectTasks()       // re-attach to still-running tasks on both sessions
        observeAppPhase()
        startNetworkMonitor()
        startPolling()
    }

    // MARK: - Public API

    func hasDownload(sceneID: String) -> Bool { items.contains { $0.id == sceneID } }

    func start(scene: StashScene, apiKey: String) {
        guard !items.contains(where: { $0.id == scene.id }) else { return }
        guard let url = scene.directFileURL(apiKey: apiKey) else { return }
        let file = scene.files.first
        let total = Int64(file?.size ?? 0)
        let n = total > 0 ? connectionCount : 1     // no size → can't range-split; single connection
        let base = ((file?.basename ?? scene.title ?? "video") as NSString).deletingPathExtension
        let ext = scene.fileContainer.isEmpty ? "mp4" : scene.fileContainer
        let item = DownloadItem(
            id: scene.id, title: scene.title ?? base, url: url,
            fileName: base, ext: ext, codec: file?.video_codec,
            width: file?.width, height: file?.height, bitRate: file?.bit_rate,
            totalBytes: total, connectionCount: n, scene: scene, apiKey: apiKey
        )
        items.insert(item, at: 0)
        startConnections(item)
        fetchSidecar(item, scene: scene, apiKey: apiKey)
    }

    /// Completed local video file for a scene (used to play a downloaded scene offline / instantly).
    func localFile(sceneID: String) -> URL? {
        if let item = items.first(where: { $0.id == sceneID }), item.state == .completed { return item.localURL }
        return nil
    }

    /// True if this scene's local file was produced by our on-device transcoder (a clean hvc1/avc1 MP4 that
    /// direct-plays). Persists across relaunch via the sidecar's `transcoded` flag.
    func wasTranscoded(sceneID: String) -> Bool {
        items.first(where: { $0.id == sceneID })?.wasTranscoded ?? false
    }

    /// Local sprite sheet downloaded alongside the video, so scrub previews work offline / instantly.
    func localSprite(sceneID: String) -> URL? {
        let url = metaDir.appendingPathComponent("\(sceneID)-sprite.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Local WebVTT sprite index downloaded alongside the video (crop rects for `localSprite`).
    func localVTT(sceneID: String) -> URL? {
        let url = metaDir.appendingPathComponent("\(sceneID).vtt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Best-effort download of the poster + sprite sheet + WebVTT alongside the video, and a Codable
    /// sidecar of the scene so the card and offline playback survive relaunch.
    private func fetchSidecar(_ item: DownloadItem, scene: StashScene, apiKey: String) {
        let meta = metaDir
        let id = scene.id
        let thumbURL = scene.thumbnailURL(apiKey: apiKey)
        let spriteURL = scene.spriteURL(apiKey: apiKey)
        let vttURL = scene.vttURL(apiKey: apiKey)
        // Sidecar JSON (scene + apiKey) written synchronously — it's tiny.
        if let data = try? JSONEncoder().encode(Sidecar(scene: scene, apiKey: apiKey, transcoded: false)) {
            try? data.write(to: meta.appendingPathComponent("\(id).json"), options: .atomic)
        }
        Task.detached(priority: .background) {
            func save(_ url: URL?, _ name: String) async -> URL? {
                guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
                let dest = meta.appendingPathComponent(name)
                return (try? data.write(to: dest, options: .atomic)) != nil ? dest : nil
            }
            let thumb = await save(thumbURL, "\(id)-thumb.jpg")
            _ = await save(spriteURL, "\(id)-sprite.jpg")
            _ = await save(vttURL, "\(id).vtt")
            if let thumb { await MainActor.run { item.localThumb = thumb } }
        }
    }

    // `transcoded` is optional so sidecars written before this field existed still decode (absent → nil).
    private struct Sidecar: Codable { let scene: StashScene; let apiKey: String; let transcoded: Bool? }

    func pause(_ item: DownloadItem) { suspend(item, auto: false) }
    func resume(_ item: DownloadItem) {
        guard item.state == .paused || item.state == .waitingForNetwork || item.state == .failed else { return }
        launch(item, reset: false)
    }
    func retry(_ item: DownloadItem) {
        // stop() (or a prior-launch orphan sweep) may have removed the sidecar. Re-fetch it from the
        // in-memory scene so a completed retry keeps its offline metadata + sprites on the next launch.
        if let scene = item.scene,
           !FileManager.default.fileExists(atPath: metaDir.appendingPathComponent("\(item.id).json").path) {
            fetchSidecar(item, scene: scene, apiKey: item.apiKey)
        }
        launch(item, reset: true)
    }

    func stop(_ item: DownloadItem) {
        cancelTasks(item, produceResumeData: false)
        item.state = .stopped
        cleanupParts(item.id)
        cleanupMeta(item.id)   // reclaim the sidecar/thumb/sprite/vtt now; retry() re-heals if resumed
        clearActive(item.id)
    }

    func delete(_ item: DownloadItem) {
        cancelTasks(item, produceResumeData: false)
        if let local = item.localURL { try? FileManager.default.removeItem(at: local) }
        cleanupParts(item.id)
        cleanupMeta(item.id)
        items.removeAll { $0.id == item.id }
    }

    /// Called when the Downloads screen re-appears: drop rows the user stopped while away.
    func pruneStopped() { items.removeAll { $0.state == .stopped } }

    // MARK: - On-device transcode

    @ObservationIgnored private var transcoders: [String: any OnDeviceTranscoder] = [:]
    /// Per-item transcode generation. A VideoToolbox call can wedge when the app is backgrounded (no GPU
    /// access) and won't return, so `cancel()` alone can't unstick the UI. Cancelling bumps this counter,
    /// which detaches the (possibly wedged) job: its late completion is ignored because its captured
    /// generation no longer matches.
    @ObservationIgnored private var transcodeGen: [String: Int] = [:]
    /// Settings of the currently-running transcode per item, so a background-interrupted transcode can be
    /// auto-restarted on return (VideoToolbox is foreground-only and has no mid-stream checkpoint).
    @ObservationIgnored private var transcodeSettingsInFlight: [String: VideoTranscoder.Settings] = [:]
    /// Items whose transcode was paused by backgrounding and should auto-resume when we return.
    @ObservationIgnored private var transcodeResumeOnForeground: [String: VideoTranscoder.Settings] = [:]

    /// Containers Apple's `AVAssetReader` can demux natively — everything else (MKV/WebM/AVI/…) has to go
    /// through the FFmpeg transcoder.
    private static let avNativeContainers: Set<String> = ["mp4", "m4v", "mov"]

    /// Re-encode a completed download in place to the chosen resolution/quality/codec (hardware
    /// VideoToolbox), replacing the offline file with the smaller/normalised copy on success.
    func transcode(_ item: DownloadItem, settings: VideoTranscoder.Settings) {
        guard item.state == .completed, let src = item.localURL, !item.transcoding else { return }
        item.transcoding = true
        item.transcodeProgress = 0
        item.transcodeTargetLabel = "\(settings.codec.label) \(settings.resolution.label)"
        item.transcodeLog = ""
        item.transcodeStatus = ""
        item.error = nil
        transcodeSettingsInFlight[item.id] = settings   // remembered so backgrounding can auto-resume it
        // Pick the engine. Apple's AVFoundation transcoder is fast and proven, but ONLY for plain H.264
        // in a native container — it chokes on HEVC even inside an MP4 (hev1 tag / 4:2:2 / 10-bit), which
        // is the "cannot decode" the user hit. Everything else — HEVC in any container, and all exotic
        // containers (MKV/WebM/AVI) — goes to the FFmpeg transcoder, which decodes it properly.
        let native = Self.avNativeContainers.contains(src.pathExtension.lowercased())
        let codec = (item.codec ?? "").lowercased()
        let isH264 = codec.contains("h264") || codec.contains("avc")
        let useAVFoundation = native && isH264
        let transcoder: any OnDeviceTranscoder = useAVFoundation ? VideoTranscoder() : FFmpegTranscoder()
        transcoders[item.id] = transcoder
        let id = item.id
        let gen = (transcodeGen[id] ?? 0) + 1
        transcodeGen[id] = gen
        // Transcode into the OS tmp dir, NOT downloadsDir: a kill/crash mid-transcode must not leave a
        // truncated `<id>.transcode.mp4` that loadCompleted() would resurrect as a ghost "completed"
        // download. tmp is also OS-purgeable, so a purged in-progress transcode just fails cleanly.
        // tmp and Application Support share the app-container volume, so the finish move stays a rename.
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).transcode.mp4")
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "transcode-\(id)") {
            // Last-seconds notice before the watchdog kills us, not extra time. Capture `transcoder`
            // directly (it's @unchecked Sendable with a lock-guarded cancel) so the handler needs no
            // main-actor hop and makes no assumption about which thread it runs on.
            transcoder.cancel()
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        Task { @MainActor in
            do {
                // Capture `item` (a main-actor Sendable @Observable) directly so the progress callback
                // never re-captures `self` across the concurrency boundary.
                try await transcoder.run(input: src, output: dest, settings: settings) { p in
                    Task { @MainActor in item.transcodeProgress = p }
                } onLog: { line in
                    Task { @MainActor in
                        // Distinct event → append. Keep the tail bounded on a long transcode.
                        var log = item.transcodeLog + line + "\n"
                        if log.count > 4000 { log = String(log.suffix(4000)) }
                        item.transcodeLog = log
                    }
                } onStatus: { line in
                    Task { @MainActor in item.transcodeStatus = line }   // live line → replace in place
                }
                self.transcodeFinished(id: id, gen: gen, output: dest, src: src, settings: settings)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                // A user cancel isn't an error to surface; anything else is. (VideoTranscoder throws its own
                // .cancelled; FFmpegTranscoder throws Swift's CancellationError.)
                let cancelled: Bool
                if error is CancellationError { cancelled = true }
                else if case VideoTranscoder.TranscodeError.cancelled = error { cancelled = true }
                else { cancelled = false }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.transcodeFailed(id: id, gen: gen, message: cancelled ? nil : message)
            }
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
    }

    /// Cancel a running transcode. Signals the engine AND resets the UI immediately — a wedged VideoToolbox
    /// call (e.g. after backgrounding) may never return to fire the normal completion, so we can't wait for
    /// it. Bumping the generation detaches that job: if it ever unblocks, its completion is ignored.
    func cancelTranscode(_ item: DownloadItem) {
        let id = item.id
        transcoders[id]?.cancel()
        transcoders[id] = nil
        transcodeSettingsInFlight[id] = nil
        transcodeGen[id] = (transcodeGen[id] ?? 0) + 1
        item.transcoding = false
        item.transcodeProgress = 0
        item.transcodeTargetLabel = nil
        item.transcodeStatus = ""
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("\(id).transcode.mp4"))
    }

    /// Wipe the diagnostics box for any item that isn't actively transcoding — called when the Downloads
    /// screen goes away, so a finished transcode's log shows while you're on the screen but is gone if you
    /// leave and come back. An in-flight transcode keeps its log/status.
    func clearFinishedTranscodeLogs() {
        for item in items where !item.transcoding {
            item.transcodeLog = ""
            item.transcodeStatus = ""
        }
    }

    private func transcodeFailed(id: String, gen: Int, message: String?) {
        guard transcodeGen[id] == gen, let item = items.first(where: { $0.id == id }) else { return }
        item.transcoding = false
        item.transcodeProgress = 0
        item.transcodeTargetLabel = nil
        if let message { item.error = message }
        transcoders[id] = nil
        transcodeSettingsInFlight[id] = nil
    }

    private func transcodeFinished(id: String, gen: Int, output: URL, src: URL, settings: VideoTranscoder.Settings) {
        transcodeSettingsInFlight[id] = nil
        guard transcodeGen[id] == gen, let item = items.first(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: output)   // detached/cancelled job — drop its temp output
            return
        }
        let fm = FileManager.default
        let finalURL = downloadsDir.appendingPathComponent("\(id).mp4")
        // Put the transcoded output in place WITHOUT destroying the original first, so a failed move can
        // never strand us with neither file. When finalURL already exists (src was already <id>.mp4)
        // replaceItemAt swaps atomically; otherwise (e.g. a .mov source → <id>.mp4) there's nothing to
        // replace, so move into place. Only after success do we drop the now-superseded original.
        do {
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: output)
            } else {
                try fm.moveItem(at: output, to: finalURL)
            }
            if src.path != finalURL.path { try? fm.removeItem(at: src) }
        } catch {
            // Move/replace failed before the original was touched — the offline copy is intact and still
            // playable, so keep the item .completed and just surface that the transcode didn't save.
            item.transcoding = false
            item.transcodeProgress = 0
            item.transcodeTargetLabel = nil
            item.error = "Couldn't save the transcoded file"
            transcoders[id] = nil
            return
        }
        let size = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? item.totalBytes
        item.localURL = finalURL
        item.ext = "mp4"
        item.totalBytes = size
        item.receivedBytes = size
        item.codec = settings.codec == .hevc ? "hevc" : "h264"
        // Reflect the downscale in the spec chips.
        if let w = item.width, let h = item.height, let cap = settings.resolution.maxDimension, max(w, h) > cap {
            let scale = Double(cap) / Double(max(w, h))
            item.width = Int((Double(w) * scale).rounded())
            item.height = Int((Double(h) * scale).rounded())
        }
        // Recompute the bitrate from the new file size + duration (both copy and re-encode change it), so
        // the card and the scene info show it instead of going blank.
        let duration = item.scene?.files.first?.duration ?? 0
        item.bitRate = duration > 0 ? Int((Double(size) * 8 / duration).rounded()) : nil
        item.transcodeProgress = 1
        item.transcoding = false
        item.transcodeTargetLabel = nil
        item.wasTranscoded = true
        // Rewrite the persisted scene metadata to match the transcoded file, so the detail view and the
        // player stats stop showing the pre-transcode container/codec/resolution — and so it survives
        // relaunch, where loadCompleted re-derives the item's specs from this sidecar.
        if let updated = item.scene?.replacingPrimaryFileSpecs(
            container: "mp4", codec: item.codec, width: item.width, height: item.height,
            bitRate: item.bitRate, size: Int(item.totalBytes)) {
            item.scene = updated
            if let data = try? JSONEncoder().encode(Sidecar(scene: updated, apiKey: item.apiKey, transcoded: true)) {
                try? data.write(to: metaDir.appendingPathComponent("\(id).json"), options: .atomic)
            }
        }
        transcoders[id] = nil
    }

    // MARK: - Launch / suspend

    private func launch(_ item: DownloadItem, reset: Bool) {
        if reset {
            cancelTasks(item, produceResumeData: false)
            cleanupParts(item.id)
            resumeData[item.id] = nil
            for i in item.connections.indices { item.connections[i].received = 0 }
            item.receivedBytes = 0
            item.error = nil
        }
        if inBackground { startBackgroundConnection(item) } else { startConnections(item) }
    }

    private func startConnections(_ item: DownloadItem) {
        item.state = .downloading
        item.error = nil
        item.lastSampleTime = Date()
        item.lastSampleBytes = item.receivedBytes
        markActive(item.id)
        var newTasks: [URLSessionDownloadTask] = []
        let done = finished[item.id] ?? []
        for i in item.connections.indices where !done.contains(i) {
            let task: URLSessionDownloadTask
            if let data = resumeData[item.id]?[i] {
                task = session.downloadTask(withResumeData: data)
            } else {
                var req = URLRequest(url: item.url)
                if item.totalBytes > 0 {
                    let (lo, hi) = chunkRange(item, i)
                    req.setValue("bytes=\(lo)-\(hi)", forHTTPHeaderField: "Range")
                }
                task = session.downloadTask(with: req)
            }
            // Persist identity so a cold background relaunch can route this task's finished file.
            task.taskDescription = "\(item.id)\u{1}\(i)\u{1}\(partURL(item.id, i).path)"
            store.register(task: task.taskIdentifier, item: item.id, conn: i, part: partURL(item.id, i))
            newTasks.append(task)
            task.resume()
        }
        tasks[item.id] = newTasks
        resumeData[item.id] = nil
        clearResumeFiles(item.id)                          // resume blobs are now consumed by live tasks
        if newTasks.isEmpty { finalizeIfComplete(item) }   // everything was already downloaded
    }

    private func suspend(_ item: DownloadItem, auto: Bool) {
        guard item.state == .downloading else { return }
        item.state = auto ? .waitingForNetwork : .paused
        cancelTasks(item, produceResumeData: true)
    }

    private func cancelTasks(_ item: DownloadItem, produceResumeData: Bool) {
        let active = tasks[item.id] ?? []
        tasks[item.id] = []
        for task in active {
            let conn = store.info(task: task.taskIdentifier)?.conn
            store.drop(task: task.taskIdentifier)
            if produceResumeData {
                task.cancel(byProducingResumeData: { [weak self] data in
                    guard let data, let conn else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        self.resumeData[item.id, default: [:]][conn] = data
                        try? data.write(to: self.resumeDataURL(item.id, conn), options: .atomic)
                    }
                })
            } else {
                task.cancel()
            }
        }
    }

    private func chunkRange(_ item: DownloadItem, _ i: Int) -> (Int64, Int64) {
        let n = item.connections.count
        let chunk = item.totalBytes / Int64(n)
        let lo = Int64(i) * chunk
        let hi = (i == n - 1) ? item.totalBytes - 1 : (Int64(i + 1) * chunk - 1)
        return (lo, hi)
    }

    // MARK: - Foreground / background handoff

    /// Move active downloads between the fast foreground engine and the suspend-surviving single-connection
    /// background engine when the app changes phase.
    private func observeAppPhase() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterForeground() }
        }
    }

    private func enterBackground() {
        guard !inBackground else { return }
        inBackground = true
        // On-device transcode uses the VideoToolbox hardware engine, which iOS denies to a backgrounded
        // app — the encode call would wedge. Stop any running transcode cleanly now, but remember its
        // settings so it AUTO-RESUMES when we return (no scary "keep Stashy open" error, no manual tap).
        // There's no mid-stream checkpoint, so the resume re-runs the transcode — but it's automatic.
        for item in items where item.transcoding {
            if let settings = transcodeSettingsInFlight[item.id] { transcodeResumeOnForeground[item.id] = settings }
            cancelTranscode(item)
            item.transcodeStatus = "Paused — resumes automatically when you reopen Stashy"
        }
        for item in items where item.state == .downloading { handoff(item, toBackground: true) }
        // Hold a short assertion so the resume-data cancellations finish and the background tasks actually
        // start before iOS suspends us (a background URLSession task, once running, then survives on its own).
        if !pendingHandoff.isEmpty, handoffAssertion == .invalid {
            handoffAssertion = UIApplication.shared.beginBackgroundTask(withName: "dl-handoff")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.endHandoffAssertion()
            }
        }
    }

    private func enterForeground() {
        guard inBackground else { return }
        inBackground = false
        for item in items where item.state == .downloading { handoff(item, toBackground: false) }
        // Auto-resume transcodes that were paused by backgrounding — no manual tap needed.
        let resumes = transcodeResumeOnForeground
        transcodeResumeOnForeground.removeAll()
        for (id, settings) in resumes {
            guard let item = items.first(where: { $0.id == id }), item.state == .completed, !item.transcoding else { continue }
            item.error = nil
            transcode(item, settings: settings)
        }
    }

    private func endHandoffAssertion() {
        guard handoffAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(handoffAssertion)
        handoffAssertion = .invalid
    }

    /// Cancel the item's in-flight tasks (saving each one's resume data), then — once every cancellation has
    /// produced its resume data — restart on the target engine: one connection on the background session, or
    /// all remaining connections in parallel on the foreground session.
    private func handoff(_ item: DownloadItem, toBackground: Bool) {
        // A prior handoff for this item is still awaiting its resume-data cancellations. That pending
        // completion re-reads the *current* phase when it fires and restarts on the right engine, so a
        // second phase flip landing mid-handoff must not clear the tasks again or start a duplicate engine
        // here — doing so orphaned the first engine's tasks and let 16 tasks write the same 8 part files.
        if pendingHandoff[item.id] != nil { return }
        let active = tasks[item.id] ?? []
        tasks[item.id] = []
        guard !active.isEmpty else {
            if toBackground { startBackgroundConnection(item) } else { startConnections(item) }
            return
        }
        pendingHandoff[item.id] = active.count
        for task in active {
            let conn = store.info(task: task.taskIdentifier)?.conn
            store.drop(task: task.taskIdentifier)
            task.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    if let data, let conn {
                        self.resumeData[item.id, default: [:]][conn] = data
                        try? data.write(to: self.resumeDataURL(item.id, conn), options: .atomic)
                    }
                    let remaining = (self.pendingHandoff[item.id] ?? 1) - 1
                    if remaining > 0 { self.pendingHandoff[item.id] = remaining; return }
                    self.pendingHandoff[item.id] = nil
                    // Only start if nothing else already did (tasks stay empty for the whole handoff window
                    // unless a start slipped in) — belt-and-suspenders against a duplicate engine.
                    if item.state == .downloading, (self.tasks[item.id] ?? []).isEmpty {
                        // Honour the *current* phase in case it flipped again mid-handoff.
                        if self.inBackground { self.startBackgroundConnection(item) }
                        else { self.startConnections(item) }
                    }
                    if self.pendingHandoff.isEmpty { self.endHandoffAssertion() }
                }
            })
        }
    }

    /// Start a single connection (the first unfinished) on the background session so it continues while the
    /// app is suspended; `connectionFinished` chains the next one. Unlike `startConnections` it preserves the
    /// other connections' saved resume data (they resume when we return to the foreground).
    private func startBackgroundConnection(_ item: DownloadItem) {
        guard item.state != .completed, item.state != .merging else { return }
        item.state = .downloading
        item.error = nil
        item.lastSampleTime = Date()
        item.lastSampleBytes = item.receivedBytes
        markActive(item.id)
        let done = finished[item.id] ?? []
        guard let i = item.connections.indices.first(where: { !done.contains($0) }) else {
            finalizeIfComplete(item); return
        }
        let task: URLSessionDownloadTask
        if let data = resumeData[item.id]?[i] {
            task = bgSession.downloadTask(withResumeData: data)
            resumeData[item.id]?[i] = nil
        } else {
            var req = URLRequest(url: item.url)
            if item.totalBytes > 0 {
                let (lo, hi) = chunkRange(item, i)
                req.setValue("bytes=\(lo)-\(hi)", forHTTPHeaderField: "Range")
            }
            task = bgSession.downloadTask(with: req)
        }
        task.taskDescription = "\(item.id)\u{1}\(i)\u{1}\(partURL(item.id, i).path)"
        store.register(task: task.taskIdentifier, item: item.id, conn: i, part: partURL(item.id, i))
        tasks[item.id] = [task]
        task.resume()
    }

    // MARK: - Completion / merge

    private func finalizeIfComplete(_ item: DownloadItem) {
        // Run the merge exactly once. Several paths can reach here (last part finishing, a foreground/
        // background handoff finding everything already done, relaunch reconciliation), and during a
        // background→foreground transition two can fire at once. A second merge would read parts the first
        // merge already deleted on success → "Couldn't assemble the file", flipping a completed download to
        // failed. Guarding on the transient/terminal states makes it idempotent.
        guard item.state != .merging, item.state != .completed else { return }
        let done = finished[item.id] ?? []
        guard done.count == item.connections.count else { return }
        item.state = .merging
        let parts = (0..<item.connections.count).map { partURL(item.id, $0) }
        let dest = downloadsDir.appendingPathComponent("\(item.id).\(item.ext)")
        // Keep the process alive long enough to assemble the file even when this fires during a background
        // relaunch (the merge is plain I/O off the main actor and can outlast the launch event window).
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "merge-\(item.id)") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        Task.detached(priority: .userInitiated) {
            let ok = Self.merge(parts: parts, into: dest)
            await MainActor.run {
                if ok {
                    item.localURL = dest
                    if item.totalBytes > 0 { item.receivedBytes = item.totalBytes }
                    for i in item.connections.indices { item.connections[i].received = item.connections[i].total }
                    item.state = .completed
                    self.clearActive(item.id)
                } else {
                    item.error = "Couldn't assemble the file"
                    item.state = .failed
                }
                self.cleanupParts(item.id)
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
            }
        }
    }

    nonisolated private static func merge(parts: [URL], into dest: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        if parts.count == 1 {   // single-connection download — nothing to concatenate
            do { try fm.moveItem(at: parts[0], to: dest); return true } catch { return false }
        }
        func fileSize(_ path: String) -> Int64 { ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        // Expected merged size = sum of the parts; used to reject a silently-short merge below.
        let expected = parts.reduce(Int64(0)) { $0 + fileSize($1.path) }
        guard fm.createFile(atPath: dest.path, contents: nil),
              let out = try? FileHandle(forWritingTo: dest) else { return false }
        defer { try? out.close() }
        do {
            for part in parts {
                guard let inHandle = try? FileHandle(forReadingFrom: part) else { return false }
                defer { try? inHandle.close() }
                // Non-optional read: a mid-file I/O error must FAIL the merge, not be mistaken for EOF (which
                // would delete the parts and mark a truncated file `.completed`). `write(contentsOf:)` is the
                // throwing API — the legacy `write(_:)` raises an UNcatchable NSException, so a disk-full
                // (ENOSPC) mid-merge crashed the whole process; peak disk use is ~2× the file here.
                while true {
                    guard let chunk = try inHandle.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
                    try out.write(contentsOf: chunk)
                }
            }
        } catch {
            return false
        }
        try? out.synchronize()   // flush to disk before sizing
        // Only declare success (→ parts deleted, item marked complete) if every byte actually landed.
        guard expected == 0 || fileSize(dest.path) == expected else { return false }
        return true
    }

    private func connectionFinished(itemID: String, conn: Int) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        finished[itemID, default: []].insert(conn)
        if conn < item.connections.count { item.connections[conn].received = item.connections[conn].total }
        if (finished[itemID] ?? []).count == item.connections.count {
            finalizeIfComplete(item)
        } else if inBackground, item.state == .downloading {
            // Single-connection background mode: this part is done, kick off the next remaining one.
            startBackgroundConnection(item)
        }
        // Foreground: the other parallel connections are still running — nothing to start here.
    }

    /// Connection lost / not connected / timed out / host unreachable — transient, so we wait and
    /// auto-resume rather than surfacing a scary (and truncated) error. The background session already
    /// rides out ordinary app-backgrounding; this covers the cases where a task still errors out.
    private static let transientNetworkCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
        NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
        NSURLErrorResourceUnavailable, NSURLErrorSecureConnectionFailed
    ]

    private func connectionFailed(itemID: String, message: String, code: Int) {
        guard let item = items.first(where: { $0.id == itemID }), item.state == .downloading else { return }
        let retries = networkRetries[itemID] ?? 0
        if Self.transientNetworkCodes.contains(code) && retries < maxNetworkRetries {
            // Pause the *whole* item with resume data and wait — resuming when connectivity is back keeps
            // the partial progress of every connection instead of restarting from zero.
            item.state = .waitingForNetwork
            item.error = nil
            cancelTasks(item, produceResumeData: true)
            scheduleNetworkRetry(item)
        } else {
            item.state = .failed
            item.error = message
            cancelTasks(item, produceResumeData: false)
        }
    }

    /// Relaunch a waiting item shortly after a transient failure if the current path is healthy (covers
    /// the case where connectivity never actually dropped, so the monitor won't fire a fresh event).
    private func scheduleNetworkRetry(_ item: DownloadItem) {
        let id = item.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  let item = self.items.first(where: { $0.id == id }),
                  item.state == .waitingForNetwork, self.pathSatisfied else { return }
            self.networkRetries[id, default: 0] += 1
            self.launch(item, reset: false)
        }
    }

    // MARK: - Poll loop (throttled UI updates)

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                self?.poll()
            }
        }
    }

    private func poll() {
        guard items.contains(where: { $0.state == .downloading || $0.state == .waitingForNetwork }) else { return }
        let snap = store.snapshot()
        for item in items where item.state == .downloading || item.state == .waitingForNetwork {
            for (taskID, bytes) in snap.received {
                if let inf = snap.info[taskID], inf.item == item.id, inf.conn < item.connections.count {
                    item.connections[inf.conn].received = bytes
                }
            }
            let sum = item.connections.reduce(Int64(0)) { $0 + $1.received }
            let now = Date()
            let dt = now.timeIntervalSince(item.lastSampleTime)
            if dt > 0.3 {
                item.speed = max(0, Double(sum - item.lastSampleBytes) / dt)
                item.lastSampleBytes = sum
                item.lastSampleTime = now
            }
            if sum > item.receivedBytes { networkRetries[item.id] = 0 }   // real progress → clear retry count
            item.receivedBytes = sum
        }
    }

    // MARK: - Network resilience

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "stashy.downloads.net"))
    }

    /// The monitor now only *resumes* waiting downloads when connectivity returns; it no longer proactively
    /// pauses healthy downloads on a path blip. The background `URLSession` (waitsForConnectivity) rides out
    /// ordinary drops itself, and proactively cancelling tasks every time the app briefly backgrounded was
    /// exactly what made a quick app-switch strand a download in "Waiting for network…".
    private func networkChanged(satisfied: Bool) {
        pathSatisfied = satisfied
        guard satisfied else { return }
        for item in items where item.state == .waitingForNetwork {
            networkRetries[item.id, default: 0] += 1
            launch(item, reset: false)
        }
    }

    // MARK: - Relaunch reconnection

    /// Rebuild in-flight download items from their sidecars so, after a suspend/relaunch, the delegate's
    /// finish callbacks have an item to update and partial progress is restored from what's on disk. Only
    /// items flagged active (a `.active` marker written while downloading) are resurrected — stopped ones
    /// are left dropped.
    private func loadInterrupted() {
        guard let sidecars = try? FileManager.default.contentsOfDirectory(at: metaDir, includingPropertiesForKeys: nil) else { return }
        for url in sidecars where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            if items.contains(where: { $0.id == id }) { continue }        // already loaded (completed)
            guard FileManager.default.fileExists(atPath: activeURL(id).path) else { continue }  // not active
            guard let sidecar = try? JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url)),
                  let fileURL = sidecar.scene.directFileURL(apiKey: sidecar.apiKey) else { continue }
            let scene = sidecar.scene
            let file = scene.files.first
            let total = Int64(file?.size ?? 0)
            let n = total > 0 ? connectionCount : 1
            let base = ((file?.basename ?? scene.title ?? "video") as NSString).deletingPathExtension
            let ext = scene.fileContainer.isEmpty ? "mp4" : scene.fileContainer
            let thumb = metaDir.appendingPathComponent("\(id)-thumb.jpg")
            let item = DownloadItem(
                id: id, title: scene.title ?? base, url: fileURL,
                fileName: base, ext: ext, codec: file?.video_codec,
                width: file?.width, height: file?.height, bitRate: file?.bit_rate,
                totalBytes: total, connectionCount: n, scene: scene, apiKey: sidecar.apiKey,
                localThumb: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil
            )
            var sum: Int64 = 0
            for i in 0..<n {
                let received = Int64((try? partURL(id, i).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                item.connections[i].received = received
                sum += received
                if item.connections[i].total > 0, received >= item.connections[i].total {
                    finished[id, default: []].insert(i)
                }
                if let data = try? Data(contentsOf: resumeDataURL(id, i)) {
                    resumeData[id, default: [:]][i] = data
                }
            }
            item.receivedBytes = sum
            item.state = .paused   // reconnectTasks() flips this to .downloading if a live task is found
            items.append(item)
        }
    }

    /// After `loadInterrupted`, assemble any item whose every connection already has a complete part
    /// (e.g. all connections finished while the app was suspended in a prior session).
    private func finalizeReadyItems() {
        for item in items where item.state == .paused {
            if (finished[item.id] ?? []).count == item.connections.count { finalizeIfComplete(item) }
        }
    }

    /// Re-attach to background tasks still running after a relaunch, registering them so progress and
    /// finish callbacks resolve to the right item. Tasks with no matching item are cancelled.
    private func reconnectTasks() {
        // Query both sessions: after a cold relaunch the still-running tasks live on the background session,
        // but a warm foreground relaunch may have foreground tasks too. URLSessionTask isn't Sendable, so
        // box the array to hand it to the main actor — safe here (we only read identifiers / call cancel).
        let handler: @Sendable ([URLSessionTask]) -> Void = { [weak self] allTasks in
            let box = UncheckedSendableBox(allTasks)
            Task { @MainActor in self?.attach(box.value) }
        }
        session.getAllTasks(completionHandler: handler)
        bgSession.getAllTasks(completionHandler: handler)
    }

    private func attach(_ allTasks: [URLSessionTask]) {
        var grouped: [String: [URLSessionDownloadTask]] = [:]
        for task in allTasks {
            guard let dl = task as? URLSessionDownloadTask, let desc = task.taskDescription else { task.cancel(); continue }
            let parts = desc.components(separatedBy: "\u{1}")
            guard parts.count == 3, let conn = Int(parts[1]),
                  items.contains(where: { $0.id == parts[0] }) else { task.cancel(); continue }
            store.register(task: dl.taskIdentifier, item: parts[0], conn: conn, part: URL(fileURLWithPath: parts[2]))
            grouped[parts[0], default: []].append(dl)
        }
        for (id, dlTasks) in grouped {
            tasks[id] = dlTasks
            if let item = items.first(where: { $0.id == id }) {
                item.state = .downloading
                item.lastSampleTime = Date()
                item.lastSampleBytes = item.receivedBytes
                // Cold *foreground* relaunch: the reattached task(s) came off the single-connection
                // background session, but `connectionFinished` only chains the next part while
                // `inBackground`, so once this lone task finishes the item would crawl at 1/8 speed and
                // then silently stall at a partial %. Hand it back to the fast 8-way foreground engine.
                // (The background-launch case is left alone — it chains correctly, and a cancel/restart
                // inside the time-boxed relaunch window is exactly what we don't want there.)
                if !inBackground { handoff(item, toBackground: false) }
            }
        }
    }

    // MARK: - Files

    /// Keep large offline media out of iCloud/iTunes backups.
    nonisolated private static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// Move downloads/meta from the old `Documents` location into the private Application Support store so
    /// offline videos from earlier builds aren't lost and no longer sit in a potentially user-visible folder.
    nonisolated private static func migrateLegacyStore(from docs: URL, downloadsDir: URL, metaDir: URL) {
        let fm = FileManager.default
        let moves = [(docs.appendingPathComponent("Downloads", isDirectory: true), downloadsDir),
                     (docs.appendingPathComponent("DownloadsMeta", isDirectory: true), metaDir)]
        for (old, new) in moves {
            guard let files = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let dest = new.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { continue }
                try? fm.moveItem(at: file, to: dest)
            }
            try? fm.removeItem(at: old)   // drop the now-empty legacy folder
        }
    }

    private func partURL(_ itemID: String, _ conn: Int) -> URL {
        partsDir.appendingPathComponent("\(itemID)-\(conn).part")
    }
    private func resumeDataURL(_ itemID: String, _ conn: Int) -> URL {
        partsDir.appendingPathComponent("\(itemID)-\(conn).resume")
    }
    private func clearResumeFiles(_ itemID: String) {
        for i in 0..<connectionCount { try? FileManager.default.removeItem(at: resumeDataURL(itemID, i)) }
    }
    private func cleanupParts(_ itemID: String) {
        for i in 0..<connectionCount {
            try? FileManager.default.removeItem(at: partURL(itemID, i))
            try? FileManager.default.removeItem(at: resumeDataURL(itemID, i))
        }
        finished[itemID] = nil
        resumeData[itemID] = nil
    }
    private func cleanupMeta(_ itemID: String) {
        for name in ["\(itemID).json", "\(itemID)-thumb.jpg", "\(itemID)-sprite.jpg", "\(itemID).vtt", "\(itemID).active"] {
            try? FileManager.default.removeItem(at: metaDir.appendingPathComponent(name))
        }
    }

    /// Reclaim sidecar meta sets (`<id>.json`, `-thumb.jpg`, `-sprite.jpg`, `.vtt`) left behind by a
    /// stopped/abandoned download or orphaned by a crash. Keyed EXACTLY like `loadInterrupted`: an id is
    /// kept only if it has a completed file in `downloadsDir` OR an `.active` marker. Both discriminators
    /// are required — completed downloads have no `.active` marker but do have a downloadsDir file, so an
    /// active-only check would wipe every completed download's sidecar. Runs once at init (before any new
    /// download writes a sidecar), so it can't race a fresh write.
    private func sweepOrphanedMeta() {
        let fm = FileManager.default
        guard let metaFiles = try? fm.contentsOfDirectory(at: metaDir, includingPropertiesForKeys: nil) else { return }
        let completedIDs: Set<String> = {
            guard let files = try? fm.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil) else { return [] }
            return Set(files.map { $0.deletingPathExtension().lastPathComponent })
        }()
        for url in metaFiles where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            if completedIDs.contains(id) { continue }                     // completed download → keep
            if fm.fileExists(atPath: activeURL(id).path) { continue }     // active / resumable → keep
            cleanupMeta(id)
        }
    }

    /// A marker distinguishing an active (resumable) download from a completed/stopped one, so relaunch
    /// only resurrects transfers the user actually wants continued.
    private func activeURL(_ itemID: String) -> URL { metaDir.appendingPathComponent("\(itemID).active") }
    private func markActive(_ itemID: String) {
        FileManager.default.createFile(atPath: activeURL(itemID).path, contents: nil)
    }
    private func clearActive(_ itemID: String) {
        try? FileManager.default.removeItem(at: activeURL(itemID))
    }

    /// Re-attach already-downloaded files on launch so the Downloads list survives app restarts, pulling
    /// scene metadata + the local thumbnail from the sidecar when present.
    private func loadCompleted() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return }
        for url in files {
            // Reclaim stray transcode temps (from builds that wrote them here, or a crash mid-transcode)
            // so they're never resurrected as ghost completed downloads.
            if url.lastPathComponent.hasSuffix(".transcode.mp4") {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            let id = url.deletingPathExtension().lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            let sidecar = try? JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: metaDir.appendingPathComponent("\(id).json")))
            let thumb = metaDir.appendingPathComponent("\(id)-thumb.jpg")
            let file = sidecar?.scene.files.first
            let item = DownloadItem(
                id: id, title: sidecar?.scene.title ?? url.lastPathComponent, url: url,
                fileName: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension,
                codec: file?.video_codec, width: file?.width, height: file?.height, bitRate: file?.bit_rate,
                totalBytes: size, connectionCount: 1,
                scene: sidecar?.scene, apiKey: sidecar?.apiKey ?? "",
                localThumb: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil
            )
            item.state = .completed
            item.wasTranscoded = sidecar?.transcoded ?? false
            item.localURL = url
            item.receivedBytes = size
            item.connections[0].received = size
            clearActive(id)   // completed files are never "active"
            items.append(item)
        }
    }
}
