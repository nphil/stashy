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
    /// Added from the ••• menu but not yet transferring — the user picks options (source, thread count,
    /// server resolution) on the card, then taps Start (`beginStaged`).
    case staged
    /// The Stashy Companion plugin is transcoding this scene server-side (HEVC/AV1) before any bytes are
    /// pulled. Drives a determinate bar from `serverJobProgress`; hands off to `.downloading` when the
    /// plugin reports the file ready.
    case serverProcessing
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
    /// The source URL to transfer. `var` because a staged item's URL is only finalised at Start (original
    /// file vs a server-transcoded `stream.mp4?resolution=…`).
    var url: URL
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

    // MARK: Staging options (chosen on the card before Start; only meaningful while `.staged`)
    /// Download a Stash server-transcoded copy (H.264 at `serverResolution`) instead of the original file.
    var useServerTranscode = false
    /// Target resolution for a server transcode. Defaults to Original (keep source resolution) — the user
    /// picks 1080p/720p/480p only when they want to downscale.
    var serverResolution: ServerQuality = .original
    /// Fast segmented transfer while foregrounded, collapsing to one durable connection in the background.
    /// False uses one full-file background task for the entire transfer.
    var multiThread = false
    // MARK: Companion (server-side plugin) transcode staging
    /// When set, Start routes through the Stashy Companion plugin to produce an iPhone-native HEVC/AV1
    /// file, then downloads that. nil = not a companion transcode (original or built-in server H.264).
    var companionCodec: StashCompanion.Codec? = nil
    /// Quality preset for a companion transcode.
    var companionQuality: CompanionQuality = .medium
    /// Live progress (0…1) of the companion server-side transcode while `.serverProcessing`.
    var serverJobProgress: Double = 0
    /// True while the companion transcode is in its VMAF ANALYSIS phase (choosing the quality knob) — drives
    /// an "Analyzing quality · X%" status distinct from the encode phase. `serverJobProgress` carries the
    /// analysis % during this phase, then restarts for the encode.
    var analyzing = false
    /// Achieved VMAF (phone model) of a completed server transcode, for the small Downloads badge. In-memory
    /// like `wasTranscoded` (not persisted to the sidecar), so it shows for the session after a transcode.
    var vmaf: Double?
    /// Stash Job id of the running companion transcode — persisted so monitoring reconnects after an app
    /// switch / kill / crash, and so a cancel can stop the right job.
    var companionJobID: String?

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

    /// Rebuild the connection segments for the source/thread-count chosen at Start (a staged item's real
    /// URL, total size, and connection count aren't known until then). Mirrors the `init` split.
    func rebuildConnections(count: Int, totalBytes: Int64) {
        self.totalBytes = totalBytes
        let n = max(1, count)
        let chunk = totalBytes / Int64(n)
        connections = (0..<n).map { i in
            let isLast = i == n - 1
            let total = totalBytes > 0 ? (isLast ? totalBytes - chunk * Int64(n - 1) : chunk) : 0
            return DownloadConnection(id: i, color: DownloadConnection.palette[i % DownloadConnection.palette.count], total: total)
        }
    }
}

private enum TransferEngine: String, Sendable { case foreground, background }

private struct TransferKey: Hashable, Sendable {
    let session: String
    let task: Int
}

private struct TransferInfo: Sendable {
    let item: String
    let conn: Int
    let part: URL
    let engine: TransferEngine
    let baseReceived: Int64
    let expectedBytes: Int64
    let rangeRequest: Bool
}

/// Cross-thread transfer bookkeeping, keyed by session as well as task identifier because separate
/// URLSessions can issue the same numeric task id.
private final class TransferStore: @unchecked Sendable {
    private let lock = NSLock()
    private var info: [TransferKey: TransferInfo] = [:]
    private var received: [TransferKey: Int64] = [:]

    func register(key: TransferKey, info value: TransferInfo) {
        lock.lock(); defer { lock.unlock() }
        info[key] = value
        received[key] = value.baseReceived
    }
    func setReceived(key: TransferKey, _ bytes: Int64) { lock.lock(); received[key] = bytes; lock.unlock() }
    func info(key: TransferKey) -> TransferInfo? { lock.lock(); defer { lock.unlock() }; return info[key] }
    func drop(key: TransferKey) { lock.lock(); info[key] = nil; received[key] = nil; lock.unlock() }
    func snapshot() -> (info: [TransferKey: TransferInfo], received: [TransferKey: Int64]) {
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
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let store: TransferStore
    let onFinish: @Sendable (String, Int, TransferEngine) -> Void
    let onError: @Sendable (String, String, Int, TransferEngine) -> Void
    let onStopped: @Sendable (String, Int, TransferEngine) -> Void
    private var terminal: Set<TransferKey> = []

    init(store: TransferStore,
         onFinish: @escaping @Sendable (String, Int, TransferEngine) -> Void,
         onError: @escaping @Sendable (String, String, Int, TransferEngine) -> Void,
         onStopped: @escaping @Sendable (String, Int, TransferEngine) -> Void) {
        self.store = store
        self.onFinish = onFinish
        self.onError = onError
        self.onStopped = onStopped
    }

    private func key(for session: URLSession, task: URLSessionTask) -> TransferKey {
        TransferKey(session: session.configuration.identifier ?? "foreground", task: task.taskIdentifier)
    }

    /// Decode persisted routing after iOS cold-launches the app for a background session callback. Seven
    /// fields are the adaptive format; three fields support a v1.0.294 task already registered at upgrade.
    private func info(for session: URLSession, task: URLSessionTask) -> TransferInfo? {
        let key = key(for: session, task: task)
        guard !terminal.contains(key) else { return nil }
        if let live = store.info(key: key) { return live }
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.components(separatedBy: "\u{1}")
        guard parts.count >= 3, let conn = Int(parts[1]) else { return nil }
        if parts.count >= 7,
           let engine = TransferEngine(rawValue: parts[3]),
           let base = Int64(parts[4]), let expected = Int64(parts[5]) {
            return TransferInfo(
                item: parts[0], conn: conn, part: URL(fileURLWithPath: parts[2]), engine: engine,
                baseReceived: base, expectedBytes: expected, rangeRequest: parts[6] == "1"
            )
        }
        return TransferInfo(
            item: parts[0], conn: conn, part: URL(fileURLWithPath: parts[2]), engine: .background,
            baseReceived: 0, expectedBytes: 0, rangeRequest: false
        )
    }

    private func fail(_ error: Error, session: URLSession, task: URLSessionTask, info: TransferInfo) {
        let key = key(for: session, task: task)
        terminal.insert(key)
        store.drop(key: key)
        let nsError = error as NSError
        let code = nsError.domain == NSURLErrorDomain ? nsError.code : NSURLErrorCannotWriteToFile
        onError(info.item, nsError.localizedDescription, code, info.engine)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let info = info(for: session, task: dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        let valid = info.rangeRequest ? http.statusCode == 206 : (200..<300).contains(http.statusCode)
        guard valid else {
            fail(URLError(.badServerResponse), session: session, task: dataTask, info: info)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    /// Foreground multi-thread tasks append each network chunk directly to durable part files. No opaque
    /// URLSession temporary file or cross-session resume blob is needed when the app backgrounds.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let info = info(for: session, task: dataTask) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: info.part.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: info.part.path) { fm.createFile(atPath: info.part.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: info.part)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            let size = ((try? fm.attributesOfItem(atPath: info.part.path))?[.size] as? NSNumber)?.int64Value ?? 0
            store.setReceived(key: key(for: session, task: dataTask), size)
        } catch {
            fail(error, session: session, task: dataTask, info: info)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = info(for: session, task: downloadTask) else { return }
        store.setReceived(key: key(for: session, task: downloadTask), info.baseReceived + totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = info(for: session, task: downloadTask) else { return }
        let fm = FileManager.default
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let valid = info.rangeRequest ? response.statusCode == 206 : (200..<300).contains(response.statusCode)
            guard valid else { throw URLError(.badServerResponse) }
            try fm.createDirectory(at: info.part.deletingLastPathComponent(), withIntermediateDirectories: true)
            if info.baseReceived == 0, !info.rangeRequest {
                if fm.fileExists(atPath: info.part.path) { try fm.removeItem(at: info.part) }
                try fm.moveItem(at: location, to: info.part)
            } else {
                let existing = ((try? fm.attributesOfItem(atPath: info.part.path))?[.size] as? NSNumber)?.int64Value ?? 0
                guard existing == info.baseReceived else { throw URLError(.cannotWriteToFile) }
                if !fm.fileExists(atPath: info.part.path) { fm.createFile(atPath: info.part.path, contents: nil) }
                let input = try FileHandle(forReadingFrom: location)
                let output = try FileHandle(forWritingTo: info.part)
                try output.seekToEnd()
                while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
                try input.close()
                try output.close()
            }
            let size = ((try? fm.attributesOfItem(atPath: info.part.path))?[.size] as? NSNumber)?.int64Value ?? 0
            guard info.expectedBytes == 0 || size == info.expectedBytes else { throw URLError(.cannotWriteToFile) }
            let key = key(for: session, task: downloadTask)
            terminal.insert(key)
            store.drop(key: key)
            onFinish(info.item, info.conn, info.engine)
        } catch {
            fail(error, session: session, task: downloadTask, info: info)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = key(for: session, task: task)
        if terminal.remove(key) != nil { return }
        guard let info = info(for: session, task: task) else { return }
        store.drop(key: key)
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                onStopped(info.item, info.conn, info.engine)
            } else {
                onError(info.item, error.localizedDescription, (error as NSError).code, info.engine)
            }
            return
        }
        // Download-task success is handled by didFinishDownloadingTo. A foreground data task completes here.
        guard info.engine == .foreground else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: info.part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if info.expectedBytes == 0 || size == info.expectedBytes {
            onFinish(info.item, info.conn, info.engine)
        } else {
            onError(info.item, "The downloaded segment was incomplete.", NSURLErrorCannotWriteToFile, info.engine)
        }
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
    /// Exact ActivityKit request failure, surfaced on Downloads so sideload/provisioning problems aren't
    /// silently indistinguishable from a lifecycle bug. Cleared after a successful activity starts.
    var liveActivityError: String?

    @ObservationIgnored private let connectionCount = 8
    @ObservationIgnored private let store = TransferStore()
    /// Multi-thread mode writes range data directly into durable parts on this in-process session.
    @ObservationIgnored private var fgSession: URLSession!
    /// Single/full downloads and the one adaptive connection that survives suspension use this session.
    @ObservationIgnored private var bgSession: URLSession!
    @ObservationIgnored private var delegate: DownloadDelegate!
    @ObservationIgnored private var foregroundTasks: [String: [URLSessionDataTask]] = [:]
    @ObservationIgnored private var backgroundTasks: [String: URLSessionDownloadTask] = [:]
    /// Foreground cancellations must drain before the background range reads the durable part sizes.
    @ObservationIgnored private var pendingForegroundStops: [String: Int] = [:]
    @ObservationIgnored private var handoffAssertion: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var resumeData: [String: [Int: Data]] = [:]
    @ObservationIgnored private var finished: [String: Set<Int>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivityTask: Task<Void, Never>?
    @ObservationIgnored private let liveActivity = DownloadLiveActivityCoordinator()
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Latest connectivity status from the monitor (whether the current path can carry traffic).
    @ObservationIgnored private var pathSatisfied = true
    /// Consecutive transient-network retries per item, so a persistently-unreachable URL eventually fails
    /// instead of retrying forever; reset when the item makes real progress.
    @ObservationIgnored private var networkRetries: [String: Int] = [:]
    private let maxNetworkRetries = 10
    /// One automatic clean restart for a legacy background range task that returns -3000 after updating.
    /// Kept separate from network retries so byte progress can't accidentally create an infinite loop.
    @ObservationIgnored private var fileRecoveryAttempts: [String: Int] = [:]
    /// True while the app is backgrounded. Transfers need no phase handoff; this only governs work such as
    /// on-device transcoding that must pause while the process is suspended.
    @ObservationIgnored private var inBackground = false
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
            onFinish: { [weak self] item, conn, engine in
                Task { @MainActor in self?.connectionFinished(itemID: item, conn: conn, engine: engine) }
            },
            onError: { [weak self] item, msg, code, engine in
                Task { @MainActor in self?.connectionFailed(itemID: item, message: msg, code: code, engine: engine) }
            },
            onStopped: { [weak self] item, conn, engine in
                Task { @MainActor in self?.connectionStopped(itemID: item, conn: conn, engine: engine) }
            }
        )
        // Serialize callbacks from both sessions. This prevents a final foreground file append from racing
        // the background engine's size snapshot during a phase transition.
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility

        let fgConfig = URLSessionConfiguration.default
        fgConfig.waitsForConnectivity = true
        fgSession = URLSession(configuration: fgConfig, delegate: delegate, delegateQueue: delegateQueue)

        let bgConfig = URLSessionConfiguration.background(withIdentifier: BackgroundDownloadSession.identifier)
        bgConfig.sessionSendsLaunchEvents = true
        bgConfig.isDiscretionary = false
        bgConfig.waitsForConnectivity = true
        bgSession = URLSession(configuration: bgConfig, delegate: delegate, delegateQueue: delegateQueue)

        inBackground = UIApplication.shared.applicationState == .background

        loadCompleted()
        loadInterrupted()      // rebuild in-flight items from sidecars so relaunch callbacks find them
        resumeInterruptedTranscodes()   // continue a transcode the app was killed mid-way through
        sweepOrphanedMeta()    // reclaim sidecars left by stopped/abandoned/crashed downloads
        finalizeReadyItems()   // any item whose parts are all present already → assemble now
        reconnectTasks()       // re-attach to still-running tasks on both sessions
        observeAppPhase()
        startNetworkMonitor()
        startPolling()
        startLiveActivitySync()
    }

    // MARK: - Public API

    func hasDownload(sceneID: String) -> Bool { items.contains { $0.id == sceneID } }

    func start(scene: StashScene, apiKey: String) {
        guard !items.contains(where: { $0.id == scene.id }) else { return }
        guard let url = scene.directFileURL(apiKey: apiKey) else { return }
        let file = scene.files.first
        let total = Int64(file?.size ?? 0)
        let base = ((file?.basename ?? scene.title ?? "video") as NSString).deletingPathExtension
        let ext = scene.fileContainer.isEmpty ? "mp4" : scene.fileContainer
        let item = DownloadItem(
            id: scene.id, title: scene.title ?? base, url: url,
            fileName: base, ext: ext, codec: file?.video_codec,
            width: file?.width, height: file?.height, bitRate: file?.bit_rate,
            totalBytes: total, connectionCount: 1, scene: scene, apiKey: apiKey
        )
        items.insert(item, at: 0)
        startConnections(item)
        fetchSidecar(item, scene: scene, apiKey: apiKey)
    }

    /// Add a scene to the Downloads list WITHOUT starting the transfer. The card then shows staging options
    /// (source, thread count, server resolution); the user taps Start → `beginStaged`. Ephemeral: no sidecar
    /// is written until the transfer begins, so an unstarted staged item simply doesn't persist across a
    /// relaunch (nothing to clean up).
    func stage(scene: StashScene, apiKey: String) {
        guard !items.contains(where: { $0.id == scene.id }) else { return }
        guard let url = scene.directFileURL(apiKey: apiKey) else { return }
        let file = scene.files.first
        let base = ((file?.basename ?? scene.title ?? "video") as NSString).deletingPathExtension
        let ext = scene.fileContainer.isEmpty ? "mp4" : scene.fileContainer
        let item = DownloadItem(
            id: scene.id, title: scene.title ?? base, url: url,
            fileName: base, ext: ext, codec: file?.video_codec,
            width: file?.width, height: file?.height, bitRate: file?.bit_rate,
            totalBytes: Int64(file?.size ?? 0), connectionCount: 1, scene: scene, apiKey: apiKey
        )
        item.state = .staged
        items.insert(item, at: 0)
    }

    /// Start a staged download with the options chosen on the card: the original file (multi/single-thread)
    /// or a server-transcoded H.264 copy at the chosen resolution (always single-connection — a live Stash
    /// transcode has no Content-Length / byte-range support). Finalises the URL + connection segments,
    /// writes the sidecar, and begins transferring.
    func beginStaged(_ item: DownloadItem) {
        guard item.state == .staged, let scene = item.scene else { return }
        let apiKey = item.apiKey
        if let codec = item.companionCodec {
            runCompanionTranscode(item, scene: scene, codec: codec)
            return
        }
        if item.useServerTranscode {
            guard let url = scene.serverTranscodeDownloadURL(resolution: item.serverResolution, apiKey: apiKey) else {
                item.error = "Server transcode isn't available for this scene"; return
            }
            item.url = url
            item.ext = "mp4"                                    // Stash server transcode is H.264/AAC MP4
            item.rebuildConnections(count: 1, totalBytes: 0)    // unknown size → single connection, plain GET
        } else {
            guard let url = scene.directFileURL(apiKey: apiKey) else {
                item.error = "This scene has no direct file URL"; return
            }
            item.url = url
            item.ext = scene.fileContainer.isEmpty ? "mp4" : scene.fileContainer
            let total = Int64(scene.files.first?.size ?? 0)
            item.rebuildConnections(count: item.multiThread && total > 0 ? connectionCount : 1,
                                    totalBytes: total)
        }
        item.error = nil
        startConnections(item)
        fetchSidecar(item, scene: scene, apiKey: apiKey)
    }

    // MARK: - Bulk download (additive; reuses stage/beginStaged/runCompanionTranscode unchanged)

    /// Companion transcodes run on a single server GPU/CPU, so they must go one at a time. `companionQueue`
    /// holds item ids waiting their turn; `companionActiveID` is the one transcoding now. No new UI/state:
    /// waiting items sit on the existing `.serverProcessing` card with a "Queued…" status.
    @ObservationIgnored private var companionQueue: [String] = []
    @ObservationIgnored private var companionActiveID: String?

    /// Bulk-download a set of scenes with one shared option. Originals and Stash H.264 transcodes start
    /// immediately (the byte engine already handles many at once, exactly as starting several by hand);
    /// Companion (plugin) transcodes are QUEUED and pumped one at a time so we never hammer the server.
    /// Purely additive: each scene flows through the same `stage`/`beginStaged`/`runCompanionTranscode` path
    /// a single download uses. Scenes already in the list are skipped.
    func bulkDownload(scenes: [StashScene], options: BulkDownloadOptions, apiKey: String) {
        for scene in scenes {
            guard !items.contains(where: { $0.id == scene.id }) else { continue }
            stage(scene: scene, apiKey: apiKey)
            guard let item = items.first(where: { $0.id == scene.id }) else { continue }
            switch options.source {
            case .original:
                item.useServerTranscode = false
                item.companionCodec = nil
                beginStaged(item)
            case .serverH264(let res):
                item.useServerTranscode = true
                item.companionCodec = nil
                item.serverResolution = res
                beginStaged(item)
            case .companion(let codec, let res, let quality):
                item.companionCodec = codec
                item.serverResolution = res
                item.companionQuality = quality
                item.state = .serverProcessing      // reuse the existing server-processing card
                item.serverJobProgress = 0
                item.transcodeStatus = "Queued…"
                // Persist the queued item (jobID nil = not yet started) + mark active so a kill/relaunch
                // restores it and resumes the queue — fire-and-forget overnight transcoding.
                persistServerSidecar(item, scene: scene, codec: codec)
                markActive(item.id)
                companionQueue.append(item.id)
            }
        }
        pumpCompanionQueue()
    }

    /// Start the next queued Companion transcode when the server is free (serial). Robust to items that were
    /// cancelled/removed while waiting (skipped).
    private func pumpCompanionQueue() {
        guard companionActiveID == nil else { return }
        while !companionQueue.isEmpty {
            let id = companionQueue.removeFirst()
            guard let item = items.first(where: { $0.id == id }),
                  item.state == .serverProcessing, let scene = item.scene,
                  let codec = item.companionCodec else { continue }
            companionActiveID = id
            item.transcodeStatus = ""
            runCompanionTranscode(item, scene: scene, codec: codec)
            return
        }
    }

    /// Free the serial slot when a bulk transcode finishes/fails/cancels and start the next. A no-op for a
    /// single (non-bulk) download — its id is never `companionActiveID` and isn't in the queue.
    private func releaseCompanionSlot(_ itemID: String) {
        companionQueue.removeAll { $0 == itemID }
        if companionActiveID == itemID {
            companionActiveID = nil
            pumpCompanionQueue()
        }
    }

    /// Ask the plugin to delete a scene's served transcode proxy after the phone has finished downloading
    /// it, so proxies don't accumulate on the server. Fire-and-forget: any failure is harmless (the plugin's
    /// cache cap / manual purge still reclaim the space). `sceneID` == the download item id.
    private func deleteServerProxy(sceneID: String, apiKey: String) {
        guard let serverURL = KeychainService.read("serverURL") else { return }
        let companion = StashCompanion(client: StashClient(serverURL: serverURL, apiKey: apiKey))
        Task { try? await companion.deleteCache(sceneID: sceneID) }
    }

    /// Kick off a Stashy Companion server-side transcode (HEVC/AV1 via the plugin's modern ffmpeg), then
    /// monitor it and hand the finished file to the normal byte-download engine. Robust across app
    /// switch/kill/crash: the job runs server-side, and we persist its id + params in a sidecar so a
    /// relaunch reconnects to the SAME job (or picks up its finished output). Rich live stats (size/ETA/
    /// fps/speed) flow through the scene's custom_fields into the same log box the on-device transcode
    /// uses. Nothing touches the load-bearing transfer path except the final `startConnections` hand-off.
    private func runCompanionTranscode(_ item: DownloadItem, scene: StashScene, codec: StashCompanion.Codec) {
        guard let serverURL = KeychainService.read("serverURL") else {
            item.state = .failed; item.error = "Not connected to a Stash server"; return
        }
        let companion = StashCompanion(client: StashClient(serverURL: serverURL, apiKey: item.apiKey))
        let resolution = item.serverResolution
        let quality = item.companionQuality
        let sceneID = scene.id
        item.state = .serverProcessing
        item.serverJobProgress = 0
        item.error = nil
        item.transcodeLog = ""
        item.transcodeStatus = ""
        item.transcodeTargetLabel = "\(codec.label) \(resolution.label)"
        appendTranscodeLog(item, "Requesting \(codec.label) \(resolution.label) transcode…")
        markActive(item.id)   // so a relaunch resurrects this item and reconnects
        syncLiveActivity()

        Task { @MainActor in
            do {
                let jobID = try await companion.requestTranscode(
                    sceneID: sceneID, codec: codec, resolution: resolution, quality: quality)
                item.companionJobID = jobID
                appendTranscodeLog(item, "Server transcoding on \(serverHostLabel(serverURL))…")
                persistServerSidecar(item, scene: scene, codec: codec)
                await monitorCompanionJob(item, scene: scene, jobID: jobID, codec: codec, companion: companion)
            } catch {
                if item.state == .serverProcessing {
                    item.state = .failed
                    item.error = "Companion plugin: \(error.localizedDescription)"
                    clearActive(item.id)
                    releaseCompanionSlot(item.id)
                }
            }
        }
    }

    /// Re-attach to a companion transcode after a relaunch (called from `loadInterrupted` for a sidecar
    /// that was mid-transcode). The Stash job kept running while we were gone; reconnect by its persisted id.
    private func reconnectCompanionTranscode(_ item: DownloadItem, scene: StashScene, jobID: String,
                                             codec: StashCompanion.Codec) {
        guard let serverURL = KeychainService.read("serverURL") else { return }
        let companion = StashCompanion(client: StashClient(serverURL: serverURL, apiKey: item.apiKey))
        item.companionJobID = jobID
        item.state = .serverProcessing
        item.transcodeTargetLabel = "\(codec.label) \(item.serverResolution.label)"
        appendTranscodeLog(item, "Reconnecting to server transcode…")
        Task { @MainActor in
            await monitorCompanionJob(item, scene: scene, jobID: jobID, codec: codec, companion: companion)
        }
    }

    /// Poll a companion job (one combined request/tick) until it produces a file (→ download) or fails.
    /// Terminal state is decided by the durable custom_fields result, so this survives Stash GC'ing the
    /// Job and survives our own app being killed and relaunched.
    private func monitorCompanionJob(_ item: DownloadItem, scene: StashScene, jobID: String,
                                     codec: StashCompanion.Codec, companion: StashCompanion) async {
        let apiKey = item.apiKey
        var lastStage = ""
        var networkFails = 0     // consecutive poll exceptions (offline / server down)
        var doneMisses = 0       // consecutive polls where the job is gone but no ready result yet
        while true {
            try? await Task.sleep(for: .milliseconds(1800))
            guard item.state == .serverProcessing else { return }   // cancelled / deleted / paused
            let update: CompanionUpdate
            do {
                update = try await companion.poll(jobID: jobID, sceneID: scene.id)
            } catch {
                networkFails += 1
                if networkFails > 40 {   // ~72s of continuous failures → give up (offline / server down)
                    item.state = .failed; item.error = "Lost contact with the server transcode"
                    clearActive(item.id); return
                }
                continue   // transient network blip — keep trying
            }
            networkFails = 0
            let result = update.result

            // Live % comes from the Job (log.progress → Job.progress). Skip during the VMAF analysis phase:
            // the plugin emits no Job.progress then (it reads 0), and clobbering the bar to 0 here — right
            // before the `await` below — makes it visibly bounce back. The analyzing branch drives the bar
            // from the served file instead.
            if !item.analyzing, let p = update.job?.progress, p >= 0 {
                item.serverJobProgress = min(1, p)
            }
            // Rich live stats (size/ETA/fps/speed) come from the plugin's SERVED progress file — the
            // plugin no longer writes them to the scene, so a running transcode fires no Scene.Update
            // hooks. custom_fields only carries the terminal ready/failed (handled below).
            if result?.status != "ready", result?.status != "failed" {
                if let stats = await fetchCompanionProgress(scene, apiKey: apiKey) {
                    if stats.stage == "analyzing" {
                        // VMAF analysis phase: the plugin emits no Job.progress here, so drive the bar +
                        // status from the served file's own analysis %.
                        item.analyzing = true
                        let frac = min(1, max(0, stats.progress ?? 0))
                        item.serverJobProgress = frac
                        item.transcodeStatus = "Analyzing quality — \(Int(frac * 100))%"
                        if lastStage != "analyzing" {
                            lastStage = "analyzing"; appendTranscodeLog(item, "Analyzing quality (VMAF)")
                        }
                    } else {
                        if item.analyzing { item.transcodeStatus = "" }   // leaving analysis → drop its % line
                        item.analyzing = false
                        let line = companionStatusLine(stats)
                        if !line.isEmpty { item.transcodeStatus = line }
                        let stage = stats.engine ?? "encoding"
                        if stage != lastStage { lastStage = stage; appendTranscodeLog(item, "Encoding · \(stage)") }
                        if (update.job?.progress ?? -1) < 0, let ot = stats.out_time, let d = stats.duration, d > 0 {
                            item.serverJobProgress = min(1, ot / d)
                        }
                    }
                }
            }

            // Success is authoritative from the durable result (ready + a path), regardless of Job state.
            if let r = result, r.status == "ready", let path = r.path,
               let url = scene.companionFileURL(path: path, apiKey: apiKey) {
                finishCompanionTranscode(item, scene: scene, result: r, url: url, codec: codec)
                return
            }
            if result?.status == "failed" || update.job?.status.uppercased() == "FAILED"
                || update.job?.status.uppercased() == "CANCELLED" {
                item.state = .failed
                item.error = update.job?.error ?? "Server transcode failed"
                clearActive(item.id); releaseCompanionSlot(item.id); return
            }
            // Job gone/finished but no ready result — tolerate a brief write race, then fail.
            let jobDone = update.job == nil || update.job?.status.uppercased() == "FINISHED"
            if jobDone && result?.status != "running" {
                doneMisses += 1
                if doneMisses > 6 {
                    item.state = .failed
                    item.error = "Server transcode ended without producing a file"
                    clearActive(item.id); releaseCompanionSlot(item.id); return
                }
            } else {
                doneMisses = 0
            }
        }
    }

    /// The transcode is done: adopt the plugin's ffprobed specs, rewrite the scene/sidecar so everything
    /// reflects the real file, and hand off to the byte-download engine.
    private func finishCompanionTranscode(_ item: DownloadItem, scene: StashScene, result: TranscodeResult,
                                          url: URL, codec: StashCompanion.Codec) {
        item.serverJobProgress = 1
        item.companionJobID = nil
        releaseCompanionSlot(item.id)   // server is free now → let the next queued bulk transcode start
        item.url = url
        item.ext = result.container ?? "mp4"
        item.codec = result.video_codec ?? result.codec ?? codec.rawValue
        if let w = result.width { item.width = w }
        if let h = result.height ?? result.resolution { item.height = h }
        let size = result.size ?? 0
        if let br = result.bitrate {
            item.bitRate = br
        } else if size > 0, let dur = scene.files.first?.duration, dur > 0 {
            item.bitRate = Int(Double(size) * 8 / dur)
        }
        item.wasTranscoded = true
        item.analyzing = false
        item.vmaf = result.vmaf   // achieved VMAF (phone model) for the Downloads badge; nil if not applied
        appendTranscodeLog(item, "Transcode complete → downloading \(item.codec?.uppercased() ?? "")")
        // Before → after size + reduction, and the VMAF target/achieved/cq, in the log box.
        if let orig = scene.files.first?.size, orig > 0, size > 0 {
            let before = ByteCountFormatter.string(fromByteCount: Int64(orig), countStyle: .file)
            let after = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let pct = Int((abs(Double(orig) - Double(size)) / Double(orig) * 100).rounded())
            appendTranscodeLog(item, "Size: \(before) → \(after) (\(pct)% \(size <= Int64(orig) ? "smaller" : "larger"))")
        }
        if let v = result.vmaf {
            var line = "VMAF: "
            if let t = result.vmaf_target { line += "target \(Int(t.rounded())) → " }
            line += "achieved \(Int(v.rounded()))"
            if let c = result.cq { line += " · cq \(c)" }
            appendTranscodeLog(item, line)
        }
        item.transcodeStatus = ""
        let transcodedScene = scene.replacingPrimaryFileSpecs(
            container: item.ext, codec: item.codec, width: item.width, height: item.height,
            bitRate: item.bitRate, size: size > 0 ? Int(size) : nil)
        item.scene = transcodedScene
        item.rebuildConnections(count: item.multiThread && size > 0 ? connectionCount : 1,
                                totalBytes: size)
        item.error = nil
        startConnections(item)                       // preserves the transfer mode selected before transcoding
        fetchSidecar(item, scene: transcodedScene, apiKey: item.apiKey, transcoded: true)
    }

    /// Fetch the plugin's SERVED live-stats file for a scene over plain HTTP. Returns nil until the plugin
    /// has written it (or once it's cleared at completion). Keeps live progress off the scene's
    /// custom_fields entirely, so a running transcode triggers no Scene.Update hooks / queued tasks.
    private func fetchCompanionProgress(_ scene: StashScene, apiKey: String) async -> TranscodeResult? {
        let path = "/plugin/\(StashCompanion.pluginID)/assets/cache/scene\(scene.id).progress.json"
        guard let url = scene.companionFileURL(path: path, apiKey: apiKey) else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData   // always read the freshest stats
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(TranscodeResult.self, from: data)
    }

    /// Append a distinct event line to the transcode log box (bounded), mirroring the on-device path.
    private func appendTranscodeLog(_ item: DownloadItem, _ line: String) {
        var log = item.transcodeLog + line + "\n"
        if log.count > 4000 { log = String(log.suffix(4000)) }
        item.transcodeLog = log
    }

    /// One-line live status from the plugin's rich status blob: "34% · 5.9× · 142 fps · ~700 MB · 5m left".
    private func companionStatusLine(_ r: TranscodeResult) -> String {
        var parts: [String] = []
        if let p = r.progress { parts.append("\(Int(p * 100))%") }
        if let s = r.speed, s > 0 { parts.append(String(format: "%.1f×", s)) }
        if let f = r.fps, f > 0 { parts.append("\(Int(f)) fps") }
        if let est = r.size_estimate, est > 0 {
            parts.append("~" + ByteCountFormatter.string(fromByteCount: est, countStyle: .file))
        } else if let sz = r.size, sz > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: sz, countStyle: .file))
        }
        if let e = r.eta, e > 0 {
            let m = e / 60, s = e % 60
            parts.append(m > 0 ? "\(m)m \(s)s left" : "\(s)s left")
        }
        return parts.joined(separator: " · ")
    }

    /// Persist the running companion job so a relaunch can reconnect to it (see `loadInterrupted`).
    private func persistServerSidecar(_ item: DownloadItem, scene: StashScene, codec: StashCompanion.Codec) {
        guard let data = try? JSONEncoder().encode(Sidecar(
            scene: scene, apiKey: item.apiKey, transcoded: false,
            multiThread: item.multiThread,
            serverProcessing: true, companionJobID: item.companionJobID,
            companionCodec: codec.rawValue, companionResolution: item.serverResolution.rawValue,
            companionQuality: item.companionQuality.rawValue)) else { return }
        try? data.write(to: metaDir.appendingPathComponent("\(item.id).json"), options: .atomic)
    }

    private func serverHostLabel(_ serverURL: String) -> String {
        URLComponents(string: serverURL)?.host ?? "server"
    }

    /// Completed local video file for a scene (used to play a downloaded scene offline / instantly).
    func localFile(sceneID: String) -> URL? {
        if let item = items.first(where: { $0.id == sceneID }), item.state == .completed { return item.localURL }
        return nil
    }

    /// The two lightweight badges a scene-grid card needs, resolved in one array walk. Keeping this as a
    /// single query avoids doubling main-actor work as cards enter the viewport in a large downloads library.
    func cardStatus(sceneID: String) -> (isDownloaded: Bool, wasTranscoded: Bool) {
        guard let item = items.first(where: { $0.id == sceneID }),
              item.state == .completed else { return (false, false) }
        return (true, item.wasTranscoded)
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
    private func fetchSidecar(_ item: DownloadItem, scene: StashScene, apiKey: String, transcoded: Bool = false) {
        let meta = metaDir
        let id = scene.id
        let thumbURL = scene.thumbnailURL(apiKey: apiKey)
        let spriteURL = scene.spriteURL(apiKey: apiKey)
        let vttURL = scene.vttURL(apiKey: apiKey)
        // Sidecar JSON (scene + apiKey + the exact download source) written synchronously — it's tiny.
        if let data = try? JSONEncoder().encode(Sidecar(
            scene: scene, apiKey: apiKey, transcoded: transcoded,
            downloadURL: item.url.absoluteString, connectionCount: item.connections.count,
            multiThread: item.multiThread,
            serverTranscode: item.useServerTranscode, downloadExt: item.ext)) {
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

    /// Rewrite only the small transfer sidecar after adaptive mode falls back to a full-file task. Avoids
    /// re-fetching poster/sprite assets and ensures a relaunch doesn't restore the rejected multi mode.
    private func persistTransferPreference(_ item: DownloadItem) {
        guard let scene = item.scene,
              let data = try? JSONEncoder().encode(Sidecar(
                scene: scene, apiKey: item.apiKey, transcoded: item.wasTranscoded,
                downloadURL: item.url.absoluteString, connectionCount: item.connections.count,
                multiThread: item.multiThread, serverTranscode: item.useServerTranscode,
                downloadExt: item.ext)) else { return }
        try? data.write(to: metaDir.appendingPathComponent("\(item.id).json"), options: .atomic)
    }

    // `transcoded` is optional so sidecars written before this field existed still decode (absent → nil).
    // The download-source fields are persisted so an interrupted download reconstructs with the EXACT URL +
    // connection count (critical for a server-transcode download — re-deriving the original file URL would
    // resume a partial transcode against the wrong source). All optional → older sidecars still decode.
    private struct Sidecar: Codable {
        let scene: StashScene
        let apiKey: String
        let transcoded: Bool?
        var downloadURL: String? = nil
        var connectionCount: Int? = nil
        var multiThread: Bool? = nil
        var serverTranscode: Bool? = nil
        var downloadExt: String? = nil
        // Companion server-transcode reconnection: written while the plugin job runs so a relaunch can
        // re-attach to the SAME job (or pick up its finished output) instead of losing it. All optional.
        var serverProcessing: Bool? = nil
        var companionJobID: String? = nil
        var companionCodec: String? = nil
        var companionResolution: String? = nil
        var companionQuality: String? = nil
    }

    func pause(_ item: DownloadItem) { suspend(item, auto: false) }
    func resume(_ item: DownloadItem) {
        guard item.state == .paused || item.state == .waitingForNetwork || item.state == .failed else { return }
        launch(item, reset: false)
    }
    func retry(_ item: DownloadItem) {
        // A companion transcode that failed BEFORE any bytes arrived means the plugin job itself failed —
        // re-run the plugin rather than trying to byte-download a file that was never produced.
        if let codec = item.companionCodec, item.receivedBytes == 0, let scene = item.scene {
            runCompanionTranscode(item, scene: scene, codec: codec)
            return
        }
        // stop() (or a prior-launch orphan sweep) may have removed the sidecar. Re-fetch it from the
        // in-memory scene so a completed retry keeps its offline metadata + sprites on the next launch.
        if let scene = item.scene,
           !FileManager.default.fileExists(atPath: metaDir.appendingPathComponent("\(item.id).json").path) {
            fetchSidecar(item, scene: scene, apiKey: item.apiKey)
        }
        launch(item, reset: true)
    }

    func stop(_ item: DownloadItem) {
        cancelCompanionJob(item)   // if a server transcode is still running, tell Stash to stop it
        releaseCompanionSlot(item.id)   // free the serial bulk-transcode slot (no-op for non-bulk)
        cancelTasks(item, produceResumeData: false)
        item.state = .stopped
        cleanupParts(item.id)
        cleanupMeta(item.id)   // reclaim the sidecar/thumb/sprite/vtt now; retry() re-heals if resumed
        clearActive(item.id)
        syncLiveActivity()
    }

    /// Tell Stash to stop the running companion transcode job so cancelling in the app actually frees the
    /// server's GPU/CPU (otherwise the plugin keeps encoding an output nobody will download). Fire-and-
    /// forget; a no-op once the transcode has finished (jobID cleared) or if we're not connected.
    private func cancelCompanionJob(_ item: DownloadItem) {
        guard let jobID = item.companionJobID,
              let serverURL = KeychainService.read("serverURL") else { return }
        item.companionJobID = nil
        let companion = StashCompanion(client: StashClient(serverURL: serverURL, apiKey: item.apiKey))
        Task { try? await companion.stopJob(jobID) }
    }

    func delete(_ item: DownloadItem) {
        item.state = .stopped   // makes any in-flight companion poll loop exit before we drop the item
        cancelTasks(item, produceResumeData: false)
        // Stop any in-flight transcode (and wipe its chunk work dir) so it doesn't keep writing to a file
        // we're about to remove; clear a leftover work dir from an unresumed transcode too.
        if item.transcoding { cancelTranscode(item) }
        else { discardWorkDir(item.id) }
        if let local = item.localURL { try? FileManager.default.removeItem(at: local) }
        cleanupParts(item.id)
        cleanupMeta(item.id)
        items.removeAll { $0.id == item.id }
        syncLiveActivity()
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

    /// After a relaunch, pick up any transcode the app was killed mid-way through (its chunk work dir +
    /// settings.json survived on disk). Resume immediately when foregrounded; otherwise defer to
    /// `enterForeground` — VideoToolbox is foreground-only. Orphan work dirs (download since deleted) are
    /// reclaimed.
    private func resumeInterruptedTranscodes() {
        let root = downloadsDir.deletingLastPathComponent().appendingPathComponent("TranscodeWork", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let id = dir.lastPathComponent
            guard let item = items.first(where: { $0.id == id }),
                  let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
                  let settings = try? JSONDecoder().decode(VideoTranscoder.Settings.self, from: data) else {
                // Orphaned (download gone), a leftover ".trash-*", or corrupt settings → reclaim off-thread
                // so it can't linger forever or stall launch.
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: dir) }
                continue
            }
            guard item.state == .completed, !item.transcoding else { continue }
            if inBackground { transcodeResumeOnForeground[id] = settings }
            else { transcode(item, settings: settings) }
        }
    }

    /// Stable per-item directory (Application Support, survives backgrounding/relaunch) holding the
    /// resumable transcode's `plan.json` + `chunk_NNNN.mp4` + `settings.json`.
    private func transcodeWorkDir(_ id: String) -> URL {
        downloadsDir.deletingLastPathComponent()
            .appendingPathComponent("TranscodeWork", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// Discard a transcode work dir without blocking the main actor: rename it aside instantly (freeing the
    /// path for an immediate re-transcode, and avoiding a race where an async delete could hit a fresh dir),
    /// then delete the possibly-large chunk contents in the background. Stray `.trash-*` dirs are reclaimed
    /// at launch by `resumeInterruptedTranscodes()`.
    private func discardWorkDir(_ id: String) {
        let dir = transcodeWorkDir(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let trash = dir.deletingLastPathComponent()
            .appendingPathComponent(".trash-\(id)-\(UUID().uuidString)", isDirectory: true)
        let target = (try? FileManager.default.moveItem(at: dir, to: trash)) != nil ? trash : dir
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: target) }
    }

    /// Re-encode a completed download in place to the chosen resolution/quality/codec (hardware
    /// VideoToolbox), replacing the offline file with the smaller/normalised copy on success.
    func transcode(_ item: DownloadItem, settings: VideoTranscoder.Settings) {
        guard item.state == .completed, let src = item.localURL, !item.transcoding else { return }
        var settings = settings
        // VMAF-calibrated bitrate for on-device HEVC encodes: reuse the server's per-scene target bitrate
        // from the VMAF map (VideoToolbox has no CRF knob, so drive its average-bitrate control with the
        // mapped number). HEVC only — the map's bitrates are HEVC; any miss ⇒ nil ⇒ the preset ladder.
        if settings.codec == .hevc, settings.bitrateOverride == nil, let sceneID = item.scene?.id {
            let sourceHeight = item.height ?? 0
            let outputHeight = settings.resolution.nominalHeight.map { min($0, sourceHeight) } ?? sourceHeight
            settings.bitrateOverride = VmafMapStore.shared.targetBitrate(
                sceneID: sceneID, outputHeight: outputHeight, quality: settings.quality)
        }
        item.transcoding = true
        item.transcodeProgress = 0
        item.transcodeTargetLabel = "\(settings.codec.label) \(settings.resolution.label)"
        item.transcodeLog = settings.bitrateOverride.map { "VMAF-calibrated bitrate ~\($0 / 1000) kbps (server map)\n" } ?? ""
        item.transcodeStatus = ""
        item.error = nil
        let id = item.id
        transcodeSettingsInFlight[id] = settings   // remembered so backgrounding can auto-resume it

        // Engine routing (see the transcode-speed analysis):
        //  • same codec + same size → FFmpegTranscoder does a near-instant lossless stream copy (incl.
        //    hev1→hvc1), so chunked re-encoding would be pointlessly slow and lossy;
        //  • short clip → the old fast engine (AVFoundation for native H.264, else FFmpeg) — checkpointing
        //    is pointless for a job that finishes in seconds, and AVFoundation avoids the FFmpeg GPU
        //    round-trip;
        //  • otherwise → the resumable chunked engine (survives background/kill).
        // Missing codec/size metadata falls through to the RESUMABLE path (a nil/unknown source is assumed
        // possibly-huge), so an unknown-but-large file never silently loses resumability. The resumable
        // engine also self-checks the stream-copy case, so a metadata-driven misroute is self-corrected.
        let srcCodec = (item.codec ?? "").lowercased()
        let sameCodec = settings.codec == .hevc
            ? (srcCodec.contains("hevc") || srcCodec.contains("h265") || srcCodec.contains("hvc"))
            : (srcCodec.contains("h264") || srcCodec.contains("avc"))
        let longEdge = max(item.width ?? 0, item.height ?? 0)
        let keepsSize: Bool = {
            guard let cap = settings.resolution.maxDimension else { return true }   // "Original" keeps size
            return longEdge > 0 && longEdge <= cap
        }()
        let duration = item.scene?.files.first?.duration ?? 0
        let streamCopyCase = sameCodec && keepsSize
        let shortEnough = duration > 0 && duration < 90

        let transcoder: any OnDeviceTranscoder
        if streamCopyCase {
            discardWorkDir(id)                       // no resume needed; drop any stale chunks off-thread
            transcoder = FFmpegTranscoder()
        } else if shortEnough {
            discardWorkDir(id)
            let native = Self.avNativeContainers.contains(src.pathExtension.lowercased())
            let isH264 = srcCodec.contains("h264") || srcCodec.contains("avc")
            transcoder = (native && isH264) ? VideoTranscoder() : FFmpegTranscoder()
        } else {
            // Resumable: chunk the re-encode into a persistent work dir so an interrupted transcode
            // (backgrounded, or the app killed) continues from the last committed chunk. Settings are
            // persisted there so even a cold relaunch can resume.
            let workDir = transcodeWorkDir(id)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(settings) {
                try? data.write(to: workDir.appendingPathComponent("settings.json"), options: .atomic)
            }
            transcoder = FFmpegResumableTranscoder(workDir: workDir)
        }
        transcoders[id] = transcoder
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
    /// - Parameter preserveResume: keep the chunk work dir so the transcode can continue (used when the
    ///   interruption is a backgrounding). A real user cancel wipes it so the next transcode starts clean.
    func cancelTranscode(_ item: DownloadItem, preserveResume: Bool = false) {
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
        if !preserveResume { discardWorkDir(id) }
    }

    /// Wipe the diagnostics box for any item that isn't actively transcoding — called when the Downloads
    /// screen goes away, so a finished transcode's log shows while you're on the screen but is gone if you
    /// leave and come back. An in-flight transcode keeps its log/status.
    func clearFinishedTranscodeLogs() {
        for item in items where !item.transcoding && item.state != .serverProcessing {
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
        // A real failure (message != nil) must not auto-retry forever at every launch — drop its work dir.
        // A cancellation (message == nil, from backgrounding) keeps it so enterForeground can resume.
        if message != nil { discardWorkDir(id) }
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
            // Drop the chunk work dir now the final file is committed — shrinks the crash window in which
            // resumeInterruptedTranscodes() could re-process an already-finished item.
            discardWorkDir(id)
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
        startConnections(item)
    }

    private func startConnections(_ item: DownloadItem) {
        let desiredCount = item.multiThread && item.totalBytes > 0 ? connectionCount : 1
        // A mode change changes the part geometry, so it is only applied before starting or on an explicit
        // retry. Normal foreground/background transitions keep the same durable eight-part layout.
        if item.connections.count != desiredCount {
            cancelTasks(item, produceResumeData: false)
            cleanupParts(item.id)
            item.rebuildConnections(count: desiredCount, totalBytes: item.totalBytes)
            item.receivedBytes = 0
            item.lastSampleBytes = 0
            if let scene = item.scene {
                fetchSidecar(item, scene: scene, apiKey: item.apiKey, transcoded: item.wasTranscoded)
            }
        }
        item.state = .downloading
        item.error = nil
        item.lastSampleTime = Date()
        item.lastSampleBytes = item.receivedBytes
        markActive(item.id)
        reconcileDurableParts(item)
        if item.connections.count == 1 {
            startFullBackgroundDownload(item)
        } else if inBackground {
            startAdaptiveBackgroundConnection(item)
        } else {
            startForegroundConnections(item)
        }
        syncLiveActivity()
    }

    private func startFullBackgroundDownload(_ item: DownloadItem) {
        guard backgroundTasks[item.id] == nil else { return }
        if (finished[item.id] ?? []).contains(0) { finalizeIfComplete(item); return }
        let task: URLSessionDownloadTask
        if let data = resumeData[item.id]?[0] {
            task = bgSession.downloadTask(withResumeData: data)
            resumeData[item.id]?[0] = nil
        } else {
            task = bgSession.downloadTask(with: URLRequest(url: item.url))
        }
        register(task, item: item, conn: 0, engine: .background, base: 0,
                 expected: item.totalBytes, rangeRequest: false)
        backgroundTasks[item.id] = task
        clearResumeFiles(item.id)
        task.resume()
    }

    /// Start durable foreground range writers for every unfinished segment except the one already owned by
    /// the background daemon. Returning to the app therefore expands back to eight connections without
    /// cancelling or duplicating the background connection.
    private func startForegroundConnections(_ item: DownloadItem) {
        guard foregroundTasks[item.id]?.isEmpty != false else { return }
        reconcileDurableParts(item)
        let backgroundConn = backgroundTasks[item.id].flatMap { taskConnection($0) }
        let done = finished[item.id] ?? []
        var started: [URLSessionDataTask] = []
        for i in item.connections.indices where !done.contains(i) && i != backgroundConn {
            let part = partURL(item.id, i)
            let base = fileSize(part)
            let (lo, hi) = chunkRange(item, i)
            guard lo + base <= hi else { continue }
            var request = URLRequest(url: item.url)
            request.setValue("bytes=\(lo + base)-\(hi)", forHTTPHeaderField: "Range")
            let task = fgSession.dataTask(with: request)
            register(task, item: item, conn: i, engine: .foreground, base: base,
                     expected: item.connections[i].total, rangeRequest: true)
            started.append(task)
            task.resume()
        }
        foregroundTasks[item.id] = started
        if started.isEmpty, backgroundTasks[item.id] == nil { finalizeIfComplete(item) }
    }

    /// Run exactly one fresh range request in the background. It appends to the durable bytes written by
    /// foreground data tasks; no resume blob ever crosses session boundaries.
    private func startAdaptiveBackgroundConnection(_ item: DownloadItem) {
        guard backgroundTasks[item.id] == nil else { return }
        reconcileDurableParts(item)
        let done = finished[item.id] ?? []
        guard let i = item.connections.indices.first(where: { !done.contains($0) }) else {
            finalizeIfComplete(item); return
        }
        let part = partURL(item.id, i)
        let base = fileSize(part)
        let (lo, hi) = chunkRange(item, i)
        guard lo + base <= hi else {
            finished[item.id, default: []].insert(i)
            startAdaptiveBackgroundConnection(item)
            return
        }
        var request = URLRequest(url: item.url)
        request.setValue("bytes=\(lo + base)-\(hi)", forHTTPHeaderField: "Range")
        let task = bgSession.downloadTask(with: request)
        register(task, item: item, conn: i, engine: .background, base: base,
                 expected: item.connections[i].total, rangeRequest: true)
        backgroundTasks[item.id] = task
        task.resume()
    }

    private func register(_ task: URLSessionTask, item: DownloadItem, conn: Int, engine: TransferEngine,
                          base: Int64, expected: Int64, rangeRequest: Bool) {
        let part = partURL(item.id, conn)
        let sessionKey = engine == .foreground ? "foreground" : BackgroundDownloadSession.identifier
        let info = TransferInfo(item: item.id, conn: conn, part: part, engine: engine,
                                baseReceived: base, expectedBytes: expected, rangeRequest: rangeRequest)
        task.taskDescription = [item.id, String(conn), part.path, engine.rawValue, String(base),
                                String(expected), rangeRequest ? "1" : "0"].joined(separator: "\u{1}")
        store.register(key: TransferKey(session: sessionKey, task: task.taskIdentifier), info: info)
    }

    private func chunkRange(_ item: DownloadItem, _ i: Int) -> (Int64, Int64) {
        let chunk = item.totalBytes / Int64(item.connections.count)
        let lo = Int64(i) * chunk
        let hi = i == item.connections.count - 1 ? item.totalBytes - 1 : Int64(i + 1) * chunk - 1
        return (lo, hi)
    }

    private func taskConnection(_ task: URLSessionTask) -> Int? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.components(separatedBy: "\u{1}")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func reconcileDurableParts(_ item: DownloadItem) {
        var sum: Int64 = 0
        for i in item.connections.indices {
            let size = min(item.connections[i].total > 0 ? item.connections[i].total : Int64.max,
                           fileSize(partURL(item.id, i)))
            item.connections[i].received = size
            sum += size
            if item.connections[i].total > 0, size >= item.connections[i].total {
                finished[item.id, default: []].insert(i)
            }
        }
        item.receivedBytes = sum
    }

    private func suspend(_ item: DownloadItem, auto: Bool) {
        guard item.state == .downloading else { return }
        item.state = auto ? .waitingForNetwork : .paused
        cancelTasks(item, produceResumeData: true)
        syncLiveActivity()
    }

    private func cancelTasks(_ item: DownloadItem, produceResumeData: Bool) {
        let foreground = foregroundTasks.removeValue(forKey: item.id) ?? []
        foreground.forEach { $0.cancel() }
        guard let background = backgroundTasks.removeValue(forKey: item.id) else { return }
        if produceResumeData, item.connections.count == 1 {
            background.cancel(byProducingResumeData: { [weak self] data in
                guard let data else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.resumeData[item.id, default: [:]][0] = data
                    try? data.write(to: self.resumeDataURL(item.id, 0), options: .atomic)
                }
            })
        } else {
            background.cancel()
        }
    }

    // MARK: - Keep-awake

    /// True while the Downloads screen is on-screen (set by the view). Combined with active work to keep
    /// the display from sleeping.
    var downloadsScreenVisible = false
    /// Any download / merge / transcode currently in progress.
    var hasActiveWork: Bool {
        items.contains { $0.state == .downloading || $0.state == .merging || $0.state == .serverProcessing || $0.transcoding }
    }
    /// Keep the screen awake when the user is watching Downloads, or whenever work is happening — an
    /// idle-sleep backgrounds the app, which would pause a foreground-only transcode.
    var keepScreenAwake: Bool { downloadsScreenVisible || hasActiveWork }

    // MARK: - Live Activity

    /// ActivityKit updates are intentionally slower than the Downloads screen's 120 ms paint loop. One
    /// real byte snapshot every two seconds is visually smooth in the Dynamic Island and avoids wasting
    /// background execution time. The activity view interpolates between snapshots using measured speed.
    private func startLiveActivitySync() {
        syncLiveActivity()
        liveActivityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.syncLiveActivity()
            }
        }
    }

    private func syncLiveActivity() {
        let state = liveActivityState()
        if let error = liveActivity.sync(state) {
            liveActivityError = error
        } else if state != nil, liveActivity.hasActivity {
            liveActivityError = nil
        }
    }

    /// Select one privacy-safe transfer to feature. Scene titles never leave the app; the Lock Screen only
    /// receives byte progress, speed/ETA, and a count when a bulk operation has multiple active jobs.
    private func liveActivityState() -> DownloadActivityAttributes.ContentState? {
        let active = items.filter {
            $0.state == .downloading || $0.state == .waitingForNetwork ||
            $0.state == .merging || $0.state == .serverProcessing
        }
        guard !active.isEmpty else { return nil }

        // Prefer bytes actively moving, then recoverable waits/finalization, then a server preparing the
        // downloadable file. This keeps a queued companion job from displacing an actual phone transfer.
        let item = active.first(where: { $0.state == .downloading })
            ?? active.first(where: { $0.state == .waitingForNetwork })
            ?? active.first(where: { $0.state == .merging })
            ?? active.first!
        let now = Date.now
        let count = active.count

        switch item.state {
        case .downloading:
            let progress = item.totalBytes > 0
                ? min(1, max(0, Double(item.receivedBytes) / Double(item.totalBytes)))
                : nil
            let statusParts = [item.speedLabel, item.etaLabel].filter { !$0.isEmpty }
            let status = statusParts.isEmpty ? "Receiving data" : statusParts.joined(separator: " · ")

            // Project a complete time interval from the latest real byte speed. ProgressView(timerInterval:)
            // advances inside the system-owned Live Activity even while Stashy's process is suspended.
            var estimatedStart: Date?
            var estimatedEnd: Date?
            if item.speed > 100, item.totalBytes > item.receivedBytes, item.totalBytes > 0 {
                estimatedStart = now.addingTimeInterval(-Double(item.receivedBytes) / item.speed)
                estimatedEnd = now.addingTimeInterval(Double(item.totalBytes - item.receivedBytes) / item.speed)
            }
            return .init(
                phase: .downloading, progress: progress,
                estimatedStart: estimatedStart, estimatedEnd: estimatedEnd,
                updatedAt: now, status: status, activeJobCount: count
            )

        case .waitingForNetwork:
            let progress = item.totalBytes > 0
                ? min(1, max(0, Double(item.receivedBytes) / Double(item.totalBytes)))
                : nil
            return .init(
                phase: .waitingForNetwork, progress: progress,
                estimatedStart: nil, estimatedEnd: nil, updatedAt: now,
                status: "Resumes automatically when the connection returns", activeJobCount: count
            )

        case .merging:
            return .init(
                phase: .preparing, progress: 1,
                estimatedStart: nil, estimatedEnd: nil, updatedAt: now,
                status: "Assembling the offline file", activeJobCount: count
            )

        case .serverProcessing:
            let detail = item.transcodeStatus.isEmpty
                ? (item.analyzing ? "Analyzing quality" : "Server is preparing the download")
                : item.transcodeStatus
            return .init(
                phase: .preparing, progress: min(1, max(0, item.serverJobProgress)),
                estimatedStart: nil, estimatedEnd: nil, updatedAt: now,
                status: String(detail.prefix(80)), activeJobCount: count
            )

        default:
            return nil
        }
    }

    // MARK: - App phase

    /// Downloads already run in the system background session. Phase changes only pause/resume work that
    /// genuinely cannot run while suspended, such as the on-device VideoToolbox transcode.
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
            cancelTranscode(item, preserveResume: true)   // keep committed chunks so it resumes, not restarts
            item.transcodeStatus = "Paused — resumes automatically when you reopen Stashy"
        }
        for item in items where item.state == .downloading && item.connections.count > 1 {
            collapseToBackground(item)
        }
        syncLiveActivity()
    }

    private func enterForeground() {
        guard inBackground else { return }
        inBackground = false
        // Auto-resume transcodes that were paused by backgrounding — no manual tap needed.
        let resumes = transcodeResumeOnForeground
        transcodeResumeOnForeground.removeAll()
        for (id, settings) in resumes {
            guard let item = items.first(where: { $0.id == id }), item.state == .completed, !item.transcoding else { continue }
            item.error = nil
            transcode(item, settings: settings)
        }
        for item in items where item.state == .downloading && item.connections.count > 1 {
            // Keep any in-flight background range; fill the other unfinished segments in parallel.
            // If foreground writers are still draining their cancellation callbacks, wait for the shared
            // delegate queue to finish those file writes before opening replacement writers.
            if pendingForegroundStops[item.id] == nil { startForegroundConnections(item) }
        }
        syncLiveActivity()
    }

    private func collapseToBackground(_ item: DownloadItem) {
        let active = foregroundTasks.removeValue(forKey: item.id) ?? []
        guard !active.isEmpty else {
            startAdaptiveBackgroundConnection(item)
            return
        }
        pendingForegroundStops[item.id] = active.count
        active.forEach { $0.cancel() }
        if handoffAssertion == .invalid {
            handoffAssertion = UIApplication.shared.beginBackgroundTask(withName: "adaptive-download-handoff") { [weak self] in
                Task { @MainActor in self?.expireAdaptiveHandoff() }
            }
        }
    }

    private func expireAdaptiveHandoff() {
        let itemIDs = Array(pendingForegroundStops.keys)
        pendingForegroundStops.removeAll()
        for itemID in itemIDs {
            guard let item = items.first(where: { $0.id == itemID }), item.state == .downloading else { continue }
            reconcileDurableParts(item)
            if inBackground { startAdaptiveBackgroundConnection(item) }
            else { startForegroundConnections(item) }
        }
        endAdaptiveHandoffAssertionIfNeeded()
    }

    private func endAdaptiveHandoffAssertionIfNeeded() {
        guard pendingForegroundStops.isEmpty, handoffAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(handoffAssertion)
        handoffAssertion = .invalid
    }

    private func connectionStopped(itemID: String, conn: Int, engine: TransferEngine) {
        guard engine == .foreground, let remaining = pendingForegroundStops[itemID] else { return }
        if remaining > 1 {
            pendingForegroundStops[itemID] = remaining - 1
            return
        }
        pendingForegroundStops[itemID] = nil
        if let item = items.first(where: { $0.id == itemID }), item.state == .downloading {
            reconcileDurableParts(item)
            if inBackground { startAdaptiveBackgroundConnection(item) }
            else { startForegroundConnections(item) }
        }
        endAdaptiveHandoffAssertionIfNeeded()
    }

    // MARK: - Completion / merge

    private func finalizeIfComplete(_ item: DownloadItem) {
        // Run the merge exactly once. Several paths can reach here (the task finishing or relaunch
        // reconciliation). A second merge would read parts the first
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
                    else { item.totalBytes = item.receivedBytes }   // unknown-size (server transcode): record the real size now
                    for i in item.connections.indices { item.connections[i].received = item.connections[i].total }
                    item.state = .completed
                    self.fileRecoveryAttempts[item.id] = nil
                    self.clearActive(item.id)
                    // Server-transcoded (Companion) download finished on the phone → delete the served proxy
                    // so transcodes don't pile up on the server. (companionCodec is nil for original /
                    // built-in-H.264 / on-device-transcoded downloads, so only true server proxies are freed.)
                    if item.companionCodec != nil { self.deleteServerProxy(sceneID: item.id, apiKey: item.apiKey) }
                } else {
                    item.error = "Couldn't assemble the file"
                    item.state = .failed
                }
                self.cleanupParts(item.id)
                self.syncLiveActivity()
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

    private func connectionFinished(itemID: String, conn: Int, engine: TransferEngine) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        if engine == .background {
            backgroundTasks[itemID] = nil
        } else {
            foregroundTasks[itemID]?.removeAll { taskConnection($0) == conn }
        }
        finished[itemID, default: []].insert(conn)
        if conn < item.connections.count { item.connections[conn].received = item.connections[conn].total }
        if (finished[itemID] ?? []).count == item.connections.count {
            finalizeIfComplete(item)
        } else if item.state == .downloading {
            if inBackground { startAdaptiveBackgroundConnection(item) }
            else { startForegroundConnections(item) }
        }
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

    private func connectionFailed(itemID: String, message: String, code: Int, engine: TransferEngine) {
        guard let item = items.first(where: { $0.id == itemID }), item.state == .downloading else { return }
        // A server output that doesn't honor byte ranges cannot use adaptive multi-threading. Collapse once
        // to the universally supported full-file background task and keep the download moving.
        if code == NSURLErrorBadServerResponse, item.multiThread {
            item.multiThread = false
            launch(item, reset: true)
            persistTransferPreference(item)
            return
        }
        // Ignore late cancellation/error callbacks from foreground tasks that the fallback just replaced.
        if engine == .foreground, !item.multiThread { return }
        if code == NSURLErrorCannotCreateFile, (fileRecoveryAttempts[itemID] ?? 0) < 1 {
            // A device/daemon that rejects even one fresh background range falls back to a 200 full-file
            // task. This also heals a v1.0.293 range task still registered at upgrade.
            fileRecoveryAttempts[itemID, default: 0] += 1
            item.multiThread = false
            launch(item, reset: true)
            persistTransferPreference(item)
            return
        }
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
        syncLiveActivity()
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
        // This poll only publishes UI progress; the transfer engines continue independently. Avoid its
        // 120 ms main-actor scan/update cadence while a library grid is delivering inertial frames.
        guard !BrowseScrollCoordinator.shared.isScrolling else { return }
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
            guard let sidecar = try? JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url)) else { continue }
            let scene = sidecar.scene
            // A bulk companion transcode that was QUEUED but never started (jobID nil) when we were killed:
            // rebuild it and re-enqueue so the serial pump resumes it — fire-and-forget survives relaunch.
            if sidecar.serverProcessing == true, sidecar.companionJobID == nil {
                let codec = StashCompanion.Codec(rawValue: sidecar.companionCodec ?? "hevc") ?? .hevc
                let f = scene.files.first
                let base = ((f?.basename ?? scene.title ?? "video") as NSString).deletingPathExtension
                let item = DownloadItem(
                    id: id, title: scene.title ?? base, url: scene.directFileURL(apiKey: sidecar.apiKey) ?? url,
                    fileName: base, ext: "mp4", codec: f?.video_codec, width: f?.width, height: f?.height,
                    bitRate: f?.bit_rate, totalBytes: 0, connectionCount: 1, scene: scene, apiKey: sidecar.apiKey,
                    localThumb: {
                        let t = metaDir.appendingPathComponent("\(id)-thumb.jpg")
                        return FileManager.default.fileExists(atPath: t.path) ? t : nil
                    }())
                item.companionCodec = codec
                item.multiThread = sidecar.multiThread ?? false
                item.serverResolution = ServerQuality(rawValue: sidecar.companionResolution ?? "p1080") ?? .p1080
                item.companionQuality = CompanionQuality(rawValue: sidecar.companionQuality ?? "medium") ?? .medium
                item.state = .serverProcessing
                item.serverJobProgress = 0
                item.transcodeStatus = "Queued…"
                items.append(item)
                companionQueue.append(item.id)
                continue
            }
            // A companion transcode that was in-flight when we were killed: the Stash job kept running.
            // Rebuild the item in .serverProcessing and reconnect to the SAME job by its persisted id.
            if sidecar.serverProcessing == true, let jobID = sidecar.companionJobID {
                let codec = StashCompanion.Codec(rawValue: sidecar.companionCodec ?? "hevc") ?? .hevc
                let f = scene.files.first
                let base = ((f?.basename ?? scene.title ?? "video") as NSString).deletingPathExtension
                let item = DownloadItem(
                    id: id, title: scene.title ?? base, url: scene.directFileURL(apiKey: sidecar.apiKey) ?? url,
                    fileName: base, ext: "mp4", codec: f?.video_codec, width: f?.width, height: f?.height,
                    bitRate: f?.bit_rate, totalBytes: 0, connectionCount: 1, scene: scene, apiKey: sidecar.apiKey,
                    localThumb: {
                        let t = metaDir.appendingPathComponent("\(id)-thumb.jpg")
                        return FileManager.default.fileExists(atPath: t.path) ? t : nil
                    }())
                item.companionCodec = codec
                item.multiThread = sidecar.multiThread ?? false
                item.serverResolution = ServerQuality(rawValue: sidecar.companionResolution ?? "p1080") ?? .p1080
                item.companionQuality = CompanionQuality(rawValue: sidecar.companionQuality ?? "medium") ?? .medium
                items.append(item)
                companionActiveID = item.id   // hold the serial slot so restored queued items wait their turn
                reconnectCompanionTranscode(item, scene: scene, jobID: jobID, codec: codec)
                continue
            }
            let file = scene.files.first
            // Prefer the persisted download source (correct for a server-transcode download); fall back to
            // the original file URL for sidecars written before this field existed.
            let fileURL: URL
            if let stored = sidecar.downloadURL, let u = URL(string: stored) { fileURL = u }
            else if let u = scene.directFileURL(apiKey: sidecar.apiKey) { fileURL = u }
            else { continue }
            let isServer = sidecar.serverTranscode ?? false
            let total = isServer ? 0 : Int64(file?.size ?? 0)     // server transcode has no known size
            let n = sidecar.connectionCount ?? (total > 0 ? connectionCount : 1)
            let base = ((file?.basename ?? scene.title ?? "video") as NSString).deletingPathExtension
            let ext = sidecar.downloadExt ?? (scene.fileContainer.isEmpty ? "mp4" : scene.fileContainer)
            let thumb = metaDir.appendingPathComponent("\(id)-thumb.jpg")
            let item = DownloadItem(
                id: id, title: scene.title ?? base, url: fileURL,
                fileName: base, ext: ext, codec: file?.video_codec,
                width: file?.width, height: file?.height, bitRate: file?.bit_rate,
                totalBytes: total, connectionCount: n, scene: scene, apiKey: sidecar.apiKey,
                localThumb: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil
            )
            item.multiThread = sidecar.multiThread ?? (n > 1)
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
        pumpCompanionQueue()   // resume any restored bulk-transcode queue (serial; waits if a job reconnected)
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
        // URLSessionTask isn't Sendable, so box the array to hand it to the main actor. The background
        // session is the only transfer engine, making a cold relaunch a straight reattachment.
        let handler: @Sendable ([URLSessionTask]) -> Void = { [weak self] allTasks in
            let box = UncheckedSendableBox(allTasks)
            Task { @MainActor in self?.attach(box.value) }
        }
        bgSession.getAllTasks(completionHandler: handler)
    }

    private func attach(_ allTasks: [URLSessionTask]) {
        for task in allTasks {
            guard let dl = task as? URLSessionDownloadTask, let desc = task.taskDescription else { task.cancel(); continue }
            let parts = desc.components(separatedBy: "\u{1}")
            guard parts.count >= 3, let conn = Int(parts[1]),
                  let item = items.first(where: { $0.id == parts[0] }),
                  conn < item.connections.count else { task.cancel(); continue }
            let base = parts.count >= 5 ? (Int64(parts[4]) ?? 0) : 0
            let expected = parts.count >= 6 ? (Int64(parts[5]) ?? item.connections[conn].total) : item.connections[conn].total
            let range = parts.count >= 7 ? parts[6] == "1" : false
            let info = TransferInfo(item: item.id, conn: conn, part: URL(fileURLWithPath: parts[2]),
                                    engine: .background, baseReceived: base,
                                    expectedBytes: expected, rangeRequest: range)
            store.register(key: TransferKey(session: BackgroundDownloadSession.identifier,
                                             task: dl.taskIdentifier), info: info)
            backgroundTasks[item.id] = dl
            item.state = .downloading
            item.lastSampleTime = Date()
            item.lastSampleBytes = item.receivedBytes
            if !inBackground, item.connections.count > 1 { startForegroundConnections(item) }
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
