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
         codec: String?, width: Int?, height: Int?, bitRate: Int?, totalBytes: Int64,
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
        self.connections = [DownloadConnection(id: 0, color: DownloadConnection.palette[0],
                                               total: totalBytes)]
    }

    /// Set the real size once Start resolves the source (a staged item's URL and size aren't known
    /// until then). One connection, so this is just the single segment's total.
    func rebuildConnections(totalBytes: Int64) {
        self.totalBytes = totalBytes
        connections = [DownloadConnection(id: 0, color: DownloadConnection.palette[0], total: totalBytes)]
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
/// NOTE: `URLSessionDataDelegate` conformance is LOAD-BEARING and must stay declared. Swift only
/// exposes these methods to the Objective-C runtime when the class declares the @objc protocol, and
/// URLSession decides whether to deliver body data with `respondsToSelector:`. Drop the conformance
/// and `didReceive data:` is silently never called: the transfer runs, the server sends every byte,
/// the task completes with NO error, and the part file is empty — which reads as "the transfer ended
/// early" and cost a full debugging round.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate,
                                      @unchecked Sendable {
    let store: TransferStore
    /// `(item, conn, engine, ranged)` — `ranged` distinguishes one landed SLICE of a sliced background
    /// transfer from a whole-file transfer that delivered everything, which decide different things.
    let onFinish: @Sendable (String, Int, TransferEngine, Bool) -> Void
    let onError: @Sendable (String, Int, String, Int, TransferEngine, Data?, Bool) -> Void
    let onStopped: @Sendable (String, Int, TransferEngine) -> Void
    private var terminal: Set<TransferKey> = []

    init(store: TransferStore,
         onFinish: @escaping @Sendable (String, Int, TransferEngine, Bool) -> Void,
         onError: @escaping @Sendable (String, Int, String, Int, TransferEngine, Data?, Bool) -> Void,
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
        // The URL-layer code ("Cannot create file") says nothing about WHY. The underlying error
        // carries the real cause — a POSIX errno, a Cocoa file error, the offending path.
        let under = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        RemoteLog.shared.event("dl-err-detail", [
            ("item", info.item), ("domain", nsError.domain), ("code", nsError.code),
            ("under", under.map { "\($0.domain):\($0.code)" }),
            ("reason", nsError.localizedFailureReason),
            ("path", nsError.userInfo[NSFilePathErrorKey] as? String),
            ("blob", nsError.userInfo[NSURLSessionDownloadTaskResumeData] != nil ? 1 : 0)])
        onError(info.item, info.conn, nsError.localizedDescription, code, info.engine,
                nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, info.rangeRequest)
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

    /// The fallback path writes every chunk straight into the durable part file, so progress survives
    /// a failure and a retry resumes with a Range header from exactly where it stopped.
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
            // Only a RANGE request has an exact expected length. For a whole-file transfer the server's
            // delivered bytes are the truth — Stash's recorded size can differ (a re-encode it hasn't
            // rescanned), and rejecting on that discrepancy would throw away a complete, correct file
            // and loop forever re-downloading it.
            if info.rangeRequest {
                guard info.expectedBytes == 0 || size == info.expectedBytes else { throw URLError(.cannotWriteToFile) }
            } else {
                guard size > 0 else { throw URLError(.cannotWriteToFile) }
            }
            let key = key(for: session, task: downloadTask)
            terminal.insert(key)
            store.drop(key: key)
            onFinish(info.item, info.conn, info.engine, info.rangeRequest)
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
                // A FAILED download task carries its resume blob in the error's userInfo — this is the
                // documented way to continue one, and the only way that survives a dropped connection.
                let nsError = error as NSError
                let under = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                RemoteLog.shared.event("dl-err-detail", [
                    ("item", info.item), ("domain", nsError.domain), ("code", nsError.code),
                    ("under", under.map { "\($0.domain):\($0.code)" }),
                    ("reason", nsError.localizedFailureReason),
                    ("path", nsError.userInfo[NSFilePathErrorKey] as? String),
                    ("blob", nsError.userInfo[NSURLSessionDownloadTaskResumeData] != nil ? 1 : 0)])
                onError(info.item, info.conn, nsError.localizedDescription, nsError.code, info.engine,
                        nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, info.rangeRequest)
            }
            return
        }
        // A background download task's success arrives via didFinishDownloadingTo; a foreground data
        // task has already written every byte itself and completes here.
        guard info.engine == .foreground else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: info.part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if info.expectedBytes == 0 || size >= info.expectedBytes {
            onFinish(info.item, info.conn, info.engine, info.rangeRequest)
        } else {
            onError(info.item, info.conn, "The transfer ended early.", NSURLErrorNetworkConnectionLost,
                    info.engine, nil, info.rangeRequest)
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

    @ObservationIgnored private let store = TransferStore()
    /// Single/full downloads and the one adaptive connection that survives suspension use this session.
    /// Fallback transport: an in-process data task that appends to our own file. It never involves
    /// the system's hand-the-file-over step, which is the one that fails with -3000.
    @ObservationIgnored private var fgSession: URLSession!
    @ObservationIgnored private var bgSession: URLSession!
    @ObservationIgnored private var foregroundTasks: [String: URLSessionDataTask] = [:]
    /// Background-execution assertions held while an in-process transfer is in flight (see
    /// `holdTransferAssertion`). Keyed by item so each transfer owns exactly one.
    @ObservationIgnored private var transferAssertions: [String: UIBackgroundTaskIdentifier] = [:]
    /// Items the daemon refused to deliver, now transferring through the in-process fallback. Sticky
    /// for the item's lifetime: once the system has failed to hand this file over twice, sending it
    /// back to the same transport just repeats the failure.
    @ObservationIgnored private var foregroundFallback: Set<String> = []
    /// Servers that answered a range request with something other than 206. In-memory, so it self-heals
    /// on relaunch and a misbehaving proxy can never permanently downgrade a capable server.
    @ObservationIgnored private var sliceUnsupported: Set<String> = []
    /// Whether the background daemon has been caught failing its hand-over with nothing durable to show
    /// for it (`-3000`). PERSISTED, because this is a property of the device/OS rather than of one file:
    /// on the owner's phone it fails at every size, and each attempt strands a slice's worth of space
    /// outside our container. Once set, transfers go straight to the in-process transport.
    /// Computed, so it needs no `@ObservationIgnored` (the macro only instruments stored properties) and
    /// no in-memory copy that could disagree with what a relaunch reads back. The verdict is stamped
    /// with the OS version that earned it and re-tested after any iOS update — a point release could fix
    /// the hand-over, and nothing else would ever clear the flag.
    private var daemonHandoverBroken: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: "daemonHandoverBroken") else { return false }
            guard defaults.string(forKey: "daemonHandoverBrokenOS") == UIDevice.current.systemVersion
            else {
                defaults.set(false, forKey: "daemonHandoverBroken")   // new OS → give it another chance
                return false
            }
            return true
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue, forKey: "daemonHandoverBroken")
            defaults.set(UIDevice.current.systemVersion, forKey: "daemonHandoverBrokenOS")
        }
    }
    @ObservationIgnored private var loggedIdentity = false
    /// Items whose transfer ran in THIS session and hasn't finished — the ones whose Live Activity card
    /// must survive a stall instead of vanishing. See `liveActivityState()`.
    @ObservationIgnored private var activityOwned: Set<String> = []
    /// How much of the file one background slice moves. Big enough that the per-slice hand-over and
    /// append are noise against a ~90 MB/s LAN transfer (~0.7 s of data), small enough that a failed
    /// hand-over costs under a second of bandwidth instead of the whole file.
    private static let sliceBytes: Int64 = 64 << 20
    @ObservationIgnored private var delegate: DownloadDelegate!
    @ObservationIgnored private var backgroundTasks: [String: URLSessionDownloadTask] = [:]
    /// Foreground cancellations must drain before the background range reads the durable part sizes.
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
    /// True until `reconnectTasks` has reported back. Restored items sit `.paused` until then, which
    /// would otherwise read as "nothing is downloading" and end the Live Activity on every background
    /// relaunch — precisely when the user most wants it.
    @ObservationIgnored private var restoringTasks = true
    /// Bumped every time a transfer starts. `cancel(byProducingResumeData:)` delivers its blob one
    /// async hop later, so without this a blob from a SUPERSEDED task can land after its replacement
    /// started and be handed to iOS next time — which rejects it and costs the whole download.
    @ObservationIgnored private var transferEpoch: [String: Int] = [:]
    /// Items whose pause is still waiting for that blob. Resuming inside the window would find nothing
    /// and silently restart a multi-GB transfer from byte 0.
    @ObservationIgnored private var awaitingBlob: Set<String> = []
    @ObservationIgnored private let downloadsDir: URL
    @ObservationIgnored private let partsDir: URL
    @ObservationIgnored private let metaDir: URL

    init() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Downloaded media + sidecars live under Application Support (private to the app — never surfaced
        // in the Files app or to other apps, unlike Documents which *can* be exposed via file-sharing), in
        // a Stashy-scoped folder excluded from iCloud/iTunes backup.
        //
        // Part files live there TOO, and must: they are not a cache, they are the resume state. iOS
        // purges ~/Library/Caches under disk pressure and does so preferentially while an app is NOT
        // running — precisely a multi-GB download minimized overnight. A reaped part is invisible to the
        // engine (every progress number is derived from part FILE SIZES via reconcileDurableParts), so it
        // surfaces as progress silently going BACKWARDS and then restarting. Parts were in Caches until
        // v1.0.307; `migrateLegacyParts` moves any in-flight ones across on first launch.
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stashy", isDirectory: true)
        downloadsDir = base.appendingPathComponent("Downloads", isDirectory: true)
        metaDir = base.appendingPathComponent("DownloadsMeta", isDirectory: true)
        partsDir = base.appendingPathComponent("DownloadParts", isDirectory: true)
        for dir in [downloadsDir, partsDir, metaDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        Self.excludeFromBackup(base)
        Self.migrateLegacyParts(from: caches.appendingPathComponent("DownloadParts", isDirectory: true),
                                to: base.appendingPathComponent("DownloadParts", isDirectory: true))
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
            onFinish: { [weak self] item, conn, engine, ranged in
                Task { @MainActor in
                    self?.connectionFinished(itemID: item, conn: conn, engine: engine, ranged: ranged)
                }
            },
            onError: { [weak self] item, conn, msg, code, engine, resume, ranged in
                Task { @MainActor in
                    self?.connectionFailed(itemID: item, conn: conn, message: msg, code: code,
                                           engine: engine, resume: resume, ranged: ranged)
                }
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
        fgConfig.timeoutIntervalForRequest = 60
        // Its OWN serial queue, NOT the background session's: that one is shared with the daemon, and a
        // backlog there can starve this task's didReceive(data:) until the connection times out with
        // zero bytes — which is exactly what the fallback was doing on every attempt.
        let fgQueue = OperationQueue()
        fgQueue.maxConcurrentOperationCount = 1
        fgQueue.qualityOfService = .userInitiated
        fgSession = URLSession(configuration: fgConfig, delegate: delegate, delegateQueue: fgQueue)

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
        sweepOrphanedParts()   // reclaim bytes left by abandoned transfers (see the function's note)
        reconnectTasks()       // re-attach to still-running tasks, then auto-continue interrupted ones
        // Safety net: if getAllTasks never reports back, don't leave the Live Activity un-endable.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.restoringTasks else { return }
            self.restoringTasks = false
            self.resumeInterruptedDownloads()
            self.syncLiveActivity()
        }
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
            totalBytes: total, scene: scene, apiKey: apiKey
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
            totalBytes: Int64(file?.size ?? 0), scene: scene, apiKey: apiKey
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
            item.rebuildConnections(totalBytes: 0)              // unknown size → plain GET, no Range
        } else {
            guard let url = scene.directFileURL(apiKey: apiKey) else {
                item.error = "This scene has no direct file URL"; return
            }
            item.url = url
            item.ext = scene.fileContainer.isEmpty ? "mp4" : scene.fileContainer
            let total = Int64(scene.files.first?.size ?? 0)
            item.rebuildConnections(                                    totalBytes: total)
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
        var qualityLogged = false   // the one-time "which VMAF map entry decided the cq" log line
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
                        // Which VMAF map entry (if any) decided the quality knob — logged once, as soon
                        // as encoding starts (Companion v0.3.8+ stamps crf_source into its status;
                        // older plugins send nothing and no line appears).
                        if !qualityLogged, let source = stats.crf_source {
                            qualityLogged = true
                            appendTranscodeLog(item, Self.qualityDecisionLine(stats: stats, source: source))
                        }
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
            // Provenance tag (Companion v0.3.8+): whether the cq came from the precomputed map or a
            // live search — the map case names the entry it read.
            switch result.crf_source {
            case "map": line += " · from map" + (result.map_res.map { " (\($0))" } ?? "")
            case "live": line += " · live analysis"
            default: break
            }
            appendTranscodeLog(item, line)
        }
        item.transcodeStatus = ""
        let transcodedScene = scene.replacingPrimaryFileSpecs(
            container: item.ext, codec: item.codec, width: item.width, height: item.height,
            bitRate: item.bitRate, size: size > 0 ? Int(size) : nil)
        item.scene = transcodedScene
        item.rebuildConnections(                                totalBytes: size)
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

    /// One log line explaining how the server transcode's quality knob was chosen — the VMAF-map entry
    /// it read, a live analysis, or the preset fallback (owner: map usage was invisible client-side).
    private static func qualityDecisionLine(stats: TranscodeResult, source: String) -> String {
        let cq = stats.cq.map(String.init) ?? "?"
        switch source {
        case "map":
            var bits: [String] = []
            if let res = stats.map_res { bits.append("\(res) entry") }
            if let e = stats.vmaf_expected { bits.append("≈VMAF \(Int(e.rounded()))") }
            if let t = stats.vmaf_target { bits.append("target \(Int(t.rounded()))") }
            let detail = bits.isEmpty ? "" : " (" + bits.joined(separator: ", ") + ")"
            return "Quality: cq \(cq) from VMAF map\(detail) — live analysis skipped"
        case "live":
            var line = "Quality: cq \(cq) from live VMAF analysis"
            if let t = stats.vmaf_target { line += " (target \(Int(t.rounded())))" }
            return line
        default:
            return "Quality: preset cq \(cq) (VMAF map/analysis not used)"
        }
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
            multiThread: false,
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
            downloadURL: item.url.absoluteString, connectionCount: 1,
            multiThread: false,
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
        /// Legacy: the transfer used to be switchable between one and eight connections. Kept so older
        /// sidecars still decode; the engine is single-connection now and ignores it.
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

    func pause(_ item: DownloadItem) {
        FileManager.default.createFile(atPath: userPausedURL(item.id).path, contents: nil)
        suspend(item, auto: false)
    }
    func resume(_ item: DownloadItem) {
        guard item.state == .paused || item.state == .waitingForNetwork || item.state == .failed else { return }
        // A pause hands us its resume blob one async hop later. Resuming inside that window would find
        // nothing and quietly restart the whole file, so wait for it — briefly, and never forever.
        guard !awaitingBlob.contains(item.id) else {
            let id = item.id
            Task { @MainActor [weak self] in
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, self.awaitingBlob.contains(id) else { break }
                }
                guard let self, let item = self.items.first(where: { $0.id == id }),
                      item.state == .paused || item.state == .waitingForNetwork || item.state == .failed
                else { return }
                self.awaitingBlob.remove(id)
                self.launch(item, reset: false)
            }
            return
        }
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
        // RESUME, don't restart. Two failure paths deliberately keep their durable parts precisely so
        // Retry can continue from them — a merge failure ("Retry re-merges instead of re-downloading")
        // and an exhausted background hold ("parts stay on disk"). An unconditional reset here deleted
        // all eight and re-fetched the whole file, making the only recovery affordance the destructive
        // one. Reset is now reserved for the cases where there is genuinely nothing to salvage.
        reconcileDurableParts(item)
        if (finished[item.id] ?? []).count == item.connections.count, item.connections.count > 0,
           item.receivedBytes > 0 {
            item.error = nil
            finalizeIfComplete(item)   // every part complete → the failure was the merge; just re-merge
            return
        }
        launch(item, reset: item.receivedBytes == 0)
    }

    func stop(_ item: DownloadItem) {
        cancelCompanionJob(item)   // if a server transcode is still running, tell Stash to stop it
        releaseCompanionSlot(item.id)   // free the serial bulk-transcode slot (no-op for non-bulk)
        cancelTasks(item, produceResumeData: false)
        releaseResumeBlob(item.id)   // otherwise the daemon keeps this download's partial file forever
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

    /// Delete ONLY the on-phone download for a scene (keeps the Stash scene). No-op if not downloaded.
    /// Used by the scene screen's "Delete Download from Phone" action.
    func deleteDownload(sceneID: String) {
        guard let item = items.first(where: { $0.id == sceneID }) else { return }
        delete(item)
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
        try? FileManager.default.removeItem(at: userPausedURL(item.id))
        // Always logged (not trace-gated): a reset is the only thing that legitimately destroys durable
        // bytes, so "how much progress did we just throw away, and who asked for it" must be visible in
        // any diagnostic session.
        if reset, item.receivedBytes > 0 {
            RemoteLog.shared.event("dl-wipe", [
                ("item", item.id), ("lost", item.receivedBytes), ("total", item.totalBytes)])
        }
        if reset {
            cancelTasks(item, produceResumeData: false)
            cleanupParts(item.id)
            releaseResumeBlob(item.id)   // let the daemon drop its partial file
            for i in item.connections.indices { item.connections[i].received = 0 }
            item.receivedBytes = 0
            item.error = nil
        }
        startConnections(item)
    }

    private func startConnections(_ item: DownloadItem) {
        if item.totalBytes > 0, item.connections.first?.total != item.totalBytes {
            item.rebuildConnections(totalBytes: item.totalBytes)
        }
        // Space, measured properly. The figure to test against is `volumeAvailableCapacity`, NOT
        // `…ForImportantUsage` — the latter counts purgeable caches iOS merely *might* reclaim and read
        // 40 GB on a phone with 4 GB genuinely free, which is exactly how a 5.5 GB download got waved
        // through and then failed at 99%.
        //
        // A SLICED background transfer stages one slice at a time, so it costs the file plus a slice —
        // the old 2× applies only to a whole-file transfer, where the system holds a complete second
        // copy in its own container until the hand-over. The in-process transport also costs one copy.
        if item.totalBytes > 0 {
            let free = availableBytesStrict()
            let margin: Int64 = 512 << 20
            let directNeed = item.totalBytes + margin
            let sliceable = !sliceUnsupported.contains(item.id)
            // With the daemon ruled out there is no staging copy to budget for at all — asking for one
            // would refuse a download that fits perfectly well on the transport we're actually using.
            let daemonNeed = daemonHandoverBroken ? directNeed
                : (sliceable ? item.totalBytes + Self.sliceBytes + margin
                             : item.totalBytes * 2 + margin)
            // Before judging, make the system release what it says it already has.
            if free > 0, free < daemonNeed, availableBytes() >= daemonNeed {
                reserveSpace(daemonNeed)
            }
            let freeAfter = availableBytesStrict()
            if freeAfter >= daemonNeed { return startAfterSpaceCheck(item) }
            if freeAfter > 0, freeAfter >= directNeed, !foregroundFallback.contains(item.id) {
                foregroundFallback.insert(item.id)
                RemoteLog.shared.event("dl-space", [
                    ("item", item.id), ("why", "route-direct"), ("need", daemonNeed),
                    ("strict", freeAfter), ("lenient", availableBytes())])
                return startAfterSpaceCheck(item)
            }
            if free > 0, free < directNeed {
                item.state = .failed
                item.error = "Not enough space for this download — needs "
                    + "\(Self.bytesLabel(directNeed)), \(Self.bytesLabel(free)) free."
                RemoteLog.shared.event("dl-space", [
                    ("item", item.id), ("why", "refuse"), ("need", directNeed),
                    ("strict", free), ("lenient", availableBytes())])
                syncLiveActivity()
                return
            }
        }
        startAfterSpaceCheck(item)
    }

    /// Everything after the space decision — split out so the pre-flight can return through it.
    private func startAfterSpaceCheck(_ item: DownloadItem) {
        item.state = .downloading
        item.error = nil
        item.lastSampleTime = Date()
        item.lastSampleBytes = item.receivedBytes
        markActive(item.id)
        reconcileDurableParts(item)
        // Make "routed to the in-process transport" a single fact rather than two conditions that every
        // downstream branch has to remember to check together. Without this, a recovery path that only
        // consulted `foregroundFallback` could hand a flagged item back to the daemon that broke it.
        if daemonHandoverBroken { foregroundFallback.insert(item.id) }
        // What the INSTALLED app's identity actually is. On a sideloaded build the signer can rewrite the
        // host bundle id or re-id the widget extension so it is no longer nested under it — and the
        // system daemons that refuse to act for us (the download hand-over, ActivityKit) key off exactly
        // that identity. Emitted on the first transfer rather than from `init`, because init runs BEFORE
        // RemoteLog is enabled and the line was silently dropped for a whole build cycle.
        if RemoteLog.isLoggingEnabled, !loggedIdentity {
            loggedIdentity = true
            RemoteLog.shared.event("dl-identity", [
                ("bundle", Bundle.main.bundleIdentifier),
                ("session", BackgroundDownloadSession.identifier),
                ("detail", DownloadLiveActivityCoordinator.bundleDiagnostic())])
        }
        if RemoteLog.isDownloadTracingEnabled {
            let sliceable = item.totalBytes > 0 && !sliceUnsupported.contains(item.id)
            let engine: String
            if foregroundFallback.contains(item.id) || daemonHandoverBroken { engine = "direct" }
            else if sliceable { engine = "slices" }
            else { engine = "whole" }
            RemoteLog.shared.event("dl-begin", [
                ("item", item.id), ("total", item.totalBytes), ("from", item.receivedBytes),
                ("engine", engine),
                ("strict", availableBytesStrict()), ("lenient", availableBytes())])
            stagingCensus("begin")
        }
        if foregroundFallback.contains(item.id) || daemonHandoverBroken { startForegroundFallback(item) }
        else { startBackgroundTransfer(item) }
        syncLiveActivity()
    }

    /// THE engine: transfer the file on the background session as a chain of durable RANGE slices.
    ///
    /// The background session is the only transport that continues while the app is suspended, so it
    /// has to be the default. Its weakness is the hand-over: the daemon streams into its own staging
    /// file and moves the result to us only at the very end, and on the owner's device that move fails
    /// with -3000 "Cannot create file" EVERY time — at 98% of a 560 MB file, 99% of a 1.45 GB one, with
    /// 6.5–8 GB genuinely free and no underlying error to name. A whole-file transfer therefore pays
    /// full bandwidth for the entire file and then throws all of it away.
    ///
    /// Slicing makes that failure cheap and usually avoids it outright:
    ///   * each slice is handed over separately, so a hand-over moves ~64 MB instead of gigabytes;
    ///   * every landed slice is APPENDED to our own part file, so progress is durable and monotonic —
    ///     the daemon never holds more than one slice's worth of bytes we could lose;
    ///   * if the hand-over is broken at any size, we find out after one slice (a second or two) instead
    ///     of at 99% of a multi-gigabyte download, and escalate to the in-process fallback having lost
    ///     almost nothing.
    /// Progress can only ever move forwards because it is read from the part file, never from bytes the
    /// daemon is still holding — that was the defect that made the island count 15 → 12 → 8.
    private func startBackgroundTransfer(_ item: DownloadItem) {
        guard backgroundTasks[item.id] == nil else { return }
        if (finished[item.id] ?? []).contains(0) { finalizeIfComplete(item); return }
        // A range needs a known length to slice, and a server that has already refused a 206 will
        // refuse the next one too. Both take the whole-file transport.
        guard item.totalBytes > 0, !sliceUnsupported.contains(item.id) else {
            return startWholeFileBackgroundDownload(item)
        }
        startBackgroundSlice(item)
    }

    /// Queue the next range slice, continuing from whatever is already durable on disk.
    private func startBackgroundSlice(_ item: DownloadItem) {
        let base = fileSize(partURL(item.id, 0))
        guard base < item.totalBytes else {
            finished[item.id, default: []].insert(0)
            finalizeIfComplete(item)
            return
        }
        let end = min(base + Self.sliceBytes, item.totalBytes) - 1
        transferEpoch[item.id, default: 0] += 1
        // A slice resumes from the part file, so any banked iOS blob describes a superseded range —
        // handing it to a later whole-file transfer would restart it at the wrong offset.
        if resumeData[item.id]?[0] != nil {
            resumeData[item.id]?[0] = nil
            clearResumeFiles(item.id)
        }
        var request = URLRequest(url: item.url)
        request.setValue("bytes=\(base)-\(end)", forHTTPHeaderField: "Range")
        let task = bgSession.downloadTask(with: request)
        // `expected` is the part's size AFTER this slice lands, which is what the delegate's
        // completeness check compares against — not the whole file's size.
        register(task, item: item, conn: 0, engine: .background, base: base,
                 expected: end + 1, rangeRequest: true)
        backgroundTasks[item.id] = task
        // Durable bytes are the floor: a slice that fails can never drag the reported figure below what
        // is already on disk.
        item.receivedBytes = max(item.receivedBytes, base)
        if let first = item.connections.indices.first {
            item.connections[first].received = max(item.connections[first].received, base)
        }
        // Measure the hand-over target BEFORE handing off, so a -3000 can be read against a known state
        // rather than inferred from an error iOS attaches nothing to.
        if RemoteLog.isDownloadTracingEnabled { probeDeliveryPath("pre-slice") }
        task.resume()
        trace("dl-slice", [("item", item.id), ("from", base), ("to", end),
                           ("total", item.totalBytes), ("free", availableBytesStrict())])
    }

    /// One full-file (200) download task. Only for transfers that cannot be sliced: an unknown size (a
    /// server transcode still being written) or a server that refused a range request.
    private func startWholeFileBackgroundDownload(_ item: DownloadItem) {
        transferEpoch[item.id, default: 0] += 1
        let task: URLSessionDownloadTask
        let resumed = resumeData[item.id]?[0] != nil
        if let data = resumeData[item.id]?[0] {
            task = bgSession.downloadTask(withResumeData: data)
            resumeData[item.id]?[0] = nil
            // Adopt the blob's offset BEFORE clearing it, so a resumed transfer shows where it is
            // picking up instead of reading 0% until the first byte callback arrives.
            item.receivedBytes = max(item.receivedBytes, Self.resumedBytes(in: data))
        } else {
            task = bgSession.downloadTask(with: URLRequest(url: item.url))
            clearResumeFiles(item.id)   // genuinely starting over — drop any stale blob on disk
        }
        register(task, item: item, conn: 0, engine: .background, base: 0,
                 expected: item.totalBytes, rangeRequest: false)
        backgroundTasks[item.id] = task
        task.resume()
        trace("dl-start", [("item", item.id), ("resumed", resumed ? 1 : 0),
                           ("total", item.totalBytes), ("free", availableBytes())])
    }

    /// Transfer the file with an in-process data task that appends straight into our own part file.
    ///
    /// This exists because the system's background download task can transfer a file perfectly and
    /// then fail to deliver it (-3000 "Cannot create file", with 47 GB free — so not space). That
    /// hand-over step is the only part we don't control, and this path doesn't have one: every chunk
    /// is written by us, so progress is durable and a retry resumes with a Range header. The trade is
    /// that it only advances while Stashy is open, so it is a fallback, never the default.
    private func startForegroundFallback(_ item: DownloadItem) {
        // In-process transfers do not run while the app is suspended — starting one from the background
        // burns a retry and returns zero bytes. Park it; enterForeground picks it up.
        guard !inBackground else {
            item.state = .waitingForNetwork
            item.error = nil
            cancelTasks(item, produceResumeData: false)
            trace("dl-fg-defer", [("item", item.id), ("bytes", item.receivedBytes)])
            syncLiveActivity()
            return
        }
        foregroundTasks.removeValue(forKey: item.id)?.cancel()   // never leave an orphan writing part 0
        cancelTasks(item, produceResumeData: false)
        let base = fileSize(partURL(item.id, 0))
        // Unlike the daemon path, these bytes are ours and on disk — report them as progress.
        item.receivedBytes = base
        if let first = item.connections.indices.first { item.connections[first].received = base }
        var request = URLRequest(url: item.url)
        if base > 0 { request.setValue("bytes=\(base)-", forHTTPHeaderField: "Range") }
        let task = fgSession.dataTask(with: request)
        register(task, item: item, conn: 0, engine: .foreground, base: base,
                 expected: item.totalBytes, rangeRequest: base > 0)
        foregroundTasks[item.id] = task
        item.state = .downloading
        item.error = nil
        task.resume()
        holdTransferAssertion(item.id)
        trace("dl-fg-fallback", [("item", item.id), ("from", base), ("total", item.totalBytes)])
    }

    /// Keep the process alive after the app is backgrounded so an in-process transfer can keep writing.
    ///
    /// The daemon path never needed this — the system owns that transfer. This one is OUR data task and
    /// stops dead the moment we're suspended, which is why the fallback used to report `-1005` with zero
    /// bytes over and over after a background trip. A background-task assertion buys iOS's execution
    /// grace (~30 s), enough for a small download to land and for a large one to reach a slice boundary
    /// instead of losing the connection outright.
    private func holdTransferAssertion(_ itemID: String) {
        guard transferAssertions[itemID] == nil else { return }
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "transfer-\(itemID)") { [weak self] in
            // Must end SYNCHRONOUSLY or iOS kills the app; the map is tidied on a hop afterwards so a
            // later release can't end an already-expired identifier a second time.
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
            Task { @MainActor in self?.transferAssertions[itemID] = nil }
        }
        guard bg != .invalid else { return }
        transferAssertions[itemID] = bg
    }

    private func releaseTransferAssertion(_ itemID: String) {
        guard let bg = transferAssertions.removeValue(forKey: itemID), bg != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bg)
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

    private func taskConnection(_ task: URLSessionTask) -> Int? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.components(separatedBy: "\u{1}")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    /// Whether a task is one slice of a ranged transfer (field 6 of the persisted routing description).
    private func taskIsRanged(_ task: URLSessionTask) -> Bool {
        guard let desc = task.taskDescription else { return false }
        let parts = desc.components(separatedBy: "\u{1}")
        return parts.count >= 7 && parts[6] == "1"
    }

    /// Bytes already transferred, per an iOS resume blob (an archived property list). The key is
    /// undocumented, so a nil result simply means "unknown" and the card shows 0 until the first live
    /// byte callback — never a reason to discard the blob itself.
    nonisolated private static func resumedBytes(in blob: Data) -> Int64 {
        guard let plist = try? PropertyListSerialization.propertyList(from: blob, format: nil),
              let dict = plist as? [String: Any],
              let n = dict["NSURLSessionResumeBytesReceived"] as? NSNumber else { return 0 }
        return n.int64Value
    }

    /// Space the system will actually let a download consume (excludes caches it can reclaim).
    private func availableBytes() -> Int64 {
        (try? downloadsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
    }

    /// Free space WITHOUT counting what iOS merely considers purgeable. `ForImportantUsage` can report
    /// tens of gigabytes on a phone that cannot actually absorb a 2 GB burst, so the two are logged
    /// side by side whenever a transfer fails to land.
    private func availableBytesStrict() -> Int64 {
        Int64((try? downloadsDir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity) ?? 0)
    }

    private static func bytesLabel(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Reclaim part files that belong to no known download.
    ///
    /// Parts moved out of `Caches` into Application Support in v1.0.307, because iOS was reaping them
    /// mid-transfer. The cost of that fix: nothing reclaims them automatically any more, so every
    /// abandoned multi-GB transfer now leaks its bytes forever. On a phone that fills up, iOS reports
    /// the shortfall as a baffling -3000 "Cannot create file" at the END of an otherwise perfect
    /// download — so this sweep is load-bearing, not tidiness.
    private func sweepOrphanedParts() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: partsDir, includingPropertiesForKeys: nil) else { return }
        let live = Set(items.map(\.id))
        var reclaimed: Int64 = 0
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent      // "<itemID>-<conn>"
            guard let dash = name.lastIndex(of: "-") else { continue }
            let id = String(name[name.startIndex..<dash])
            guard !live.contains(id) else { continue }
            reclaimed += fileSize(url)
            try? fm.removeItem(at: url)
        }
        if reclaimed > 0 {
            RemoteLog.shared.event("dl-sweep", [("reclaimed", reclaimed), ("free", availableBytes())])
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Download tracing (Settings → Diagnostics → Download tracing)

    /// High-frequency diagnostic event. Gated separately from `RemoteLog.isLoggingEnabled` so a long
    /// transfer's per-slice detail is opt-in; structural events call `RemoteLog.shared.event` directly.
    private func trace(_ tag: String, _ fields: [(String, Any?)]) {
        guard RemoteLog.isDownloadTracingEnabled else { return }
        RemoteLog.shared.event(tag, fields)
    }

    /// The single most useful line for diagnosing a transfer: the real on-disk size of every part,
    /// alongside what the UI believes and which engines are live. A background regression shows up here
    /// as a part shrinking (or the sum dropping below a previous census).
    private func partCensus(_ item: DownloadItem, _ why: String) {
        guard RemoteLog.isDownloadTracingEnabled else { return }
        let sizes = item.connections.indices
            .map { String(fileSize(partURL(item.id, $0)) / 1024) }
            .joined(separator: ",")
        let pct: Int? = item.totalBytes > 0
            ? Int(Double(item.receivedBytes) / Double(item.totalBytes) * 100) : nil
        RemoteLog.shared.event("dl-parts", [
            ("item", item.id), ("why", why), ("kb", sizes),
            ("sum", item.receivedBytes), ("total", item.totalBytes), ("pct", pct),
            ("bg", backgroundTasks[item.id] != nil ? 1 : 0),
            ("done", (finished[item.id] ?? []).count),
            ("state", String(describing: item.state))])
    }

    /// The daemon streams into ITS OWN temp file and only hands us the result at completion, so part 0
    /// is empty for the whole transfer and then suddenly whole. This can therefore only ever CONFIRM
    /// completion — it must never lower `receivedBytes`, which the delegate's byte callbacks own.
    /// (The old segmented engine appended to parts continuously, which is why this used to recompute
    /// the total from disk; doing that now would zero a live download's progress on every call.)
    private func reconcileDurableParts(_ item: DownloadItem) {
        guard let first = item.connections.indices.first else { return }
        let size = fileSize(partURL(item.id, first))
        guard size > 0 else { return }
        item.connections[first].received = size
        item.receivedBytes = max(item.receivedBytes, size)
        if item.connections[first].total > 0, size >= item.connections[first].total {
            finished[item.id, default: []].insert(first)
        }
    }

    private func suspend(_ item: DownloadItem, auto: Bool) {
        guard item.state == .downloading else { return }
        item.state = auto ? .waitingForNetwork : .paused
        // Register the drain barrier BEFORE cancelling: a cancelled data task's buffered chunks still
        // append to its durable part until its completion callback lands. Any relaunch that snapshots
        // a part size mid-drain starts a writer at a stale offset — the append guard then trips (-3003).
        cancelTasks(item, produceResumeData: true)
        syncLiveActivity()
    }

    private func cancelTasks(_ item: DownloadItem, produceResumeData: Bool) {
        foregroundTasks.removeValue(forKey: item.id)?.cancel()
        releaseTransferAssertion(item.id)   // nothing of ours is writing any more
        guard let background = backgroundTasks.removeValue(forKey: item.id) else { return }
        let conn = taskConnection(background) ?? 0
        // A SLICED transfer must never bank an iOS resume blob. Its resume state is our own part file,
        // which is strictly better (it survives relaunch and iOS purges), and the blob would describe a
        // single range — reporting bytes that live only inside the daemon's staging file and inflating
        // progress above what is actually saved.
        if produceResumeData, !taskIsRanged(background) {
            let id = item.id
            let epoch = transferEpoch[id] ?? 0
            awaitingBlob.insert(id)
            background.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    self.awaitingBlob.remove(id)
                    // A newer transfer already started: this blob points at a temp file iOS has
                    // superseded, and handing it back would fail the next download outright.
                    guard let data, self.transferEpoch[id] ?? 0 == epoch else { return }
                    self.resumeData[id, default: [:]][conn] = data
                    if let item = self.items.first(where: { $0.id == id }) {
                        item.receivedBytes = max(item.receivedBytes, Self.resumedBytes(in: data))
                    }
                    try? data.write(to: self.resumeDataURL(id, conn), options: .atomic)
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

    /// Aggregate live progress for the floating status button: the mean fraction across every active
    /// item (bytes for transfers, job % for server transcodes, frames for on-device transcodes; a merge
    /// counts as full), or nil when nothing is active — the button hides. Rides the same observable
    /// fields the Downloads screen renders, so it updates with the existing 120 ms poll (which already
    /// pauses while a grid is scrolling — zero scroll-perf cost).
    var floatingStatus: (progress: Double, count: Int)? {
        var fractions: [Double] = []
        for item in items {
            if item.transcoding {
                fractions.append(min(1, max(0, item.transcodeProgress)))
                continue
            }
            switch item.state {
            case .downloading, .waitingForNetwork:
                fractions.append(item.totalBytes > 0
                                 ? min(1, Double(item.receivedBytes) / Double(item.totalBytes)) : 0)
            case .serverProcessing:
                fractions.append(min(1, max(0, item.serverJobProgress)))
            case .merging:
                fractions.append(1)
            default:
                break
            }
        }
        guard !fractions.isEmpty else { return nil }
        return (fractions.reduce(0, +) / Double(fractions.count), fractions.count)
    }

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
        if state == nil, restoringTasks { return }
        logActivityPush(state)
        if let error = liveActivity.sync(state) {
            if liveActivityError != error {
                RemoteLog.shared.event("dl-la-error", [
                    ("msg", String(error.prefix(140))),
                    ("bundle", DownloadLiveActivityCoordinator.bundleDiagnostic())])
            }
            liveActivityError = error
        } else if state != nil, liveActivity.hasActivity {
            liveActivityError = nil
        }
    }

    @ObservationIgnored private var lastLoggedActivityPct = -1
    @ObservationIgnored private var lastLoggedActivityPhase = ""

    /// Record what the Live Activity was actually handed, so a Dynamic Island report can be checked
    /// against the values the app pushed. Emitted on a phase change, a ≥2 point move, or ANY decrease —
    /// a percentage going backwards is the signature of uncommitted background bytes being re-read from
    /// disk, so it is deliberately never filtered out.
    private func logActivityPush(_ state: DownloadActivityAttributes.ContentState?) {
        guard RemoteLog.isDownloadTracingEnabled else { return }
        guard let state else {
            guard lastLoggedActivityPct >= 0 || !lastLoggedActivityPhase.isEmpty else { return }
            lastLoggedActivityPct = -1
            lastLoggedActivityPhase = ""
            RemoteLog.shared.event("dl-la", [("push", "end")])
            return
        }
        let pct = state.progress.map { Int(($0 * 100).rounded()) } ?? -1
        let phase = String(describing: state.phase)
        let decreased = lastLoggedActivityPct >= 0 && pct < lastLoggedActivityPct
        let moved = abs(pct - lastLoggedActivityPct) >= 2 || phase != lastLoggedActivityPhase
        guard decreased || moved else { return }
        lastLoggedActivityPct = pct
        lastLoggedActivityPhase = phase
        let regressed: Int? = decreased ? 1 : nil
        RemoteLog.shared.event("dl-la", [
            ("pct", pct), ("phase", phase), ("jobs", state.activeJobCount),
            ("down", regressed), ("status", String(state.status.prefix(40)))])
    }

    /// Select one privacy-safe transfer to feature. Scene titles never leave the app; the Lock Screen only
    /// receives byte progress, speed/ETA, and a count when a bulk operation has multiple active jobs.
    private func liveActivityState() -> DownloadActivityAttributes.ContentState? {
        // A card is "owned" from the moment its transfer runs until it finishes or is stopped. Owned
        // items stay on the Lock Screen even when they stall, because an island that silently
        // DISAPPEARS is the worst possible report — the owner watched one vanish mid-transfer with no
        // way to tell a finished download from an abandoned one. Ownership is per-session and never
        // covers an item merely restored as failed at launch, so a card can't come back from the dead.
        for item in items where item.state == .downloading || item.state == .serverProcessing {
            activityOwned.insert(item.id)
        }
        for item in items where item.state == .completed || item.state == .stopped {
            activityOwned.remove(item.id)
        }
        activityOwned.formIntersection(items.map(\.id))   // deleted items take their card with them

        let active = items.filter {
            $0.state == .downloading || $0.state == .waitingForNetwork ||
            $0.state == .merging || $0.state == .serverProcessing ||
            (($0.state == .paused || $0.state == .failed) && activityOwned.contains($0.id))
        }
        guard !active.isEmpty else { return nil }

        // Prefer bytes actively moving, then recoverable waits/finalization, then a server preparing the
        // downloadable file. This keeps a queued companion job from displacing an actual phone transfer.
        let item = active.first(where: { $0.state == .downloading })
            ?? active.first(where: { $0.state == .waitingForNetwork })
            ?? active.first(where: { $0.state == .merging })
            ?? active.first(where: { $0.state == .serverProcessing })
            ?? active.first!
        let now = Date.now
        let count = active.count

        switch item.state {
        case .downloading:
            let shownBytes = item.receivedBytes
            let progress = item.totalBytes > 0
                ? min(1, max(0, Double(shownBytes) / Double(item.totalBytes)))
                : nil
            let statusParts = [item.speedLabel, item.etaLabel].filter { !$0.isEmpty }
            let status = statusParts.isEmpty ? "Receiving data" : statusParts.joined(separator: " · ")

            // Project a complete time interval from the latest real byte speed. ProgressView(timerInterval:)
            // advances inside the system-owned Live Activity even while Stashy's process is suspended.
            var estimatedStart: Date?
            var estimatedEnd: Date?
            if item.speed > 100, item.totalBytes > shownBytes, item.totalBytes > 0 {
                estimatedStart = now.addingTimeInterval(-Double(shownBytes) / item.speed)
                estimatedEnd = now.addingTimeInterval(Double(item.totalBytes - shownBytes) / item.speed)
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

        case .paused, .failed:
            // Progress reads from the durable part file, so what this shows is what has actually been
            // saved and will be resumed from — never a figure that can evaporate.
            let progress = item.totalBytes > 0
                ? min(1, max(0, Double(item.receivedBytes) / Double(item.totalBytes)))
                : nil
            let saved: String = item.receivedBytes > 0
                ? " — \(Self.bytesLabel(item.receivedBytes)) saved" : ""
            let stopped: String = item.error ?? "Stopped\(saved) · open Stashy to retry"
            let status: String = item.state == .paused
                ? "Paused\(saved) · resume in Stashy"
                : String(stopped.prefix(80))
            return .init(
                phase: .waitingForNetwork, progress: progress,
                estimatedStart: nil, estimatedEnd: nil, updatedAt: now,
                status: status, activeJobCount: count
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
        // Transfers need NOTHING here: they run on the background session, which the system keeps
        // going while we're suspended and which relaunches us to deliver the finished file. The Live
        // Activity carries on from its measured ETA until we run again and can push real bytes.
        let live = items.filter { $0.state == .downloading }
        RemoteLog.shared.event("dl-phase", [("to", "background"), ("active", live.count)])
        for item in live { partCensus(item, "enter-bg") }
        syncLiveActivity()
        RemoteLog.shared.flushNow()   // the periodic timer stops once we're suspended
    }

    private func enterForeground() {
        guard inBackground else { return }
        inBackground = false
        // First thing on waking: publish everything the background run buffered, then census the real
        // on-disk state before any engine restarts and overwrites the evidence.
        RemoteLog.shared.flushNow()
        let live = items.filter { $0.state == .downloading || $0.state == .paused }
        RemoteLog.shared.event("dl-phase", [("to", "foreground"), ("active", live.count)])
        for item in live { partCensus(item, "enter-fg") }
        // Auto-resume transcodes that were paused by backgrounding — no manual tap needed.
        let resumes = transcodeResumeOnForeground
        transcodeResumeOnForeground.removeAll()
        for (id, settings) in resumes {
            guard let item = items.first(where: { $0.id == id }), item.state == .completed, !item.transcoding else { continue }
            item.error = nil
            transcode(item, settings: settings)
        }
        // A download marked `.downloading` with no live daemon task lost its task while we were away
        // (a rare daemon-side failure, or a relaunch that raced reconnectTasks). Restart it from
        // whatever the resume blob holds; a fresh foreground session also deserves fresh retries.
        fileRecoveryAttempts.removeAll()
        for item in items where (item.state == .downloading || item.state == .waitingForNetwork)
            && backgroundTasks[item.id] == nil {
            guard foregroundTasks[item.id] == nil else { continue }
            guard item.state == .downloading || foregroundFallback.contains(item.id) else { continue }
            trace("dl-revive", [("item", item.id), ("bytes", item.receivedBytes)])
            // A fallback item resumes on the fallback — its bytes are in OUR part file, and the
            // daemon would start over from zero and overwrite them.
            if foregroundFallback.contains(item.id) || daemonHandoverBroken { startForegroundFallback(item) }
            else { startBackgroundTransfer(item) }
        }
        syncLiveActivity()
    }

    /// A task we cancelled ourselves (pause, stop, reset). Nothing to do — the resume blob, if iOS
    /// produced one, was already captured in `cancelTasks`.
    private func connectionStopped(itemID: String, conn: Int, engine: TransferEngine) {}

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
                    self.cleanupParts(item.id)   // success: the parts are consumed, reclaim them
                } else {
                    item.error = "Couldn't assemble the file"
                    item.state = .failed
                    // KEEP the durable parts on failure — Retry resumes from them instead of re-downloading
                    // everything (the old cleanup here forced a from-zero restart) — and log the evidence
                    // (per-part size vs expected) so the failing chain is identifiable from the owner's ntfy.
                    let sizes = item.connections.indices.map { i in
                        "\(i):\(self.fileSize(self.partURL(item.id, i)))/\(item.connections[i].total)"
                    }
                    RemoteLog.shared.event("dl-merge-fail", [
                        ("item", item.id), ("conns", item.connections.count),
                        ("total", item.totalBytes), ("parts", sizes.joined(separator: " "))])
                }
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

    private func connectionFinished(itemID: String, conn: Int, engine: TransferEngine, ranged: Bool) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        backgroundTasks[itemID] = nil
        foregroundTasks[itemID] = nil
        releaseTransferAssertion(itemID)
        // A cold background relaunch rebuilds items as .paused before `reconnectTasks` can flip them,
        // and the app is relaunched precisely BECAUSE a task reached a terminal state — so that task is
        // already gone from `getAllTasks` and the state never flips. Without adoption the finished
        // full-file transfer would sit paused instead of finalizing, and the Live Activity, seeing
        // nothing active, ended itself. A delegate callback arriving for a paused item proves the
        // transfer is live: a user pause cancels its tasks, which routes to connectionStopped instead.
        if item.state == .paused, engine == .background {
            item.state = .downloading
            trace("dl-adopt", [("item", itemID), ("conn", conn), ("bytes", item.receivedBytes)])
        }
        let delivered = fileSize(partURL(itemID, conn))
        // A sliced background transfer lands ONE range at a time. Its part grows with every slice, so a
        // short part means "ask for the next slice", not "the download is complete". The bytes just
        // committed are durable, which is the whole point: nothing here can be undone by a later failure.
        if ranged, engine == .background, item.totalBytes > 0, delivered < item.totalBytes {
            item.receivedBytes = max(item.receivedBytes, delivered)
            if conn < item.connections.count { item.connections[conn].received = delivered }
            // A slice that landed proves both the transport and the connection are healthy — neither
            // budget should carry a grudge from an earlier failure into the rest of the file.
            fileRecoveryAttempts[itemID] = nil
            networkRetries[itemID] = 0
            trace("dl-slice-done", [("item", itemID), ("at", delivered), ("total", item.totalBytes)])
            guard item.state == .downloading else { return }   // paused/stopped between slices
            startBackgroundSlice(item)
            syncLiveActivity()
            return
        }
        finished[itemID, default: []].insert(conn)
        // Adopt what actually arrived: unknown-size transfers (server transcodes) learn their size
        // here, and a scanned-size mismatch resolves in favour of the delivered file. Never for a range
        // request, whose length we chose ourselves — that would record a slice boundary as the file size.
        if delivered > 0, !ranged {
            item.totalBytes = delivered
            if conn < item.connections.count { item.connections[conn].total = delivered }
        }
        if conn < item.connections.count { item.connections[conn].received = item.connections[conn].total }
        finalizeIfComplete(item)
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

    private func connectionFailed(itemID: String, conn: Int, message: String, code: Int,
                                  engine: TransferEngine, resume: Data?, ranged: Bool) {
        // Log BEFORE the state guard. A failure arriving for an item that is paused, restored, or already
        // terminal was previously swallowed in silence — which is exactly the case a background relaunch
        // produces, and exactly the case we most need to see. Log only; the guard still owns the control
        // flow below.
        guard let item = items.first(where: { $0.id == itemID }) else {
            RemoteLog.shared.event("dl-err", [
                ("item", itemID), ("code", code), ("state", "gone"),
                ("msg", String(message.prefix(60)))])
            return
        }
        guard item.state == .downloading else {
            RemoteLog.shared.event("dl-err", [
                ("item", itemID), ("code", code), ("state", String(describing: item.state)),
                ("bytes", item.receivedBytes), ("msg", String(message.prefix(60)))])
            return
        }
        backgroundTasks[itemID] = nil
        foregroundTasks[itemID] = nil
        releaseTransferAssertion(itemID)
        // A failed SLICE leaves nothing in flight, so the part file is the whole truth. Its abandoned
        // in-flight bytes must be dropped from the reported figure now — carrying them would overstate
        // progress until the next slice lands and then correct itself with a visible backwards tick,
        // which is the exact symptom this engine exists to eliminate.
        if ranged, let first = item.connections.indices.first {
            let durable = fileSize(partURL(itemID, first))
            item.connections[first].received = durable
            item.receivedBytes = durable
        }
        // Bank the resume blob FIRST. Without it every dropped connection restarts the file from byte
        // zero, which is exactly what a spotty cellular link produces over and over. Never for a slice:
        // its blob counts bytes INSIDE the aborted range, none of which are durable, so adopting them
        // would claim progress that does not exist on disk.
        if !ranged, let resume {
            resumeData[itemID, default: [:]][0] = resume
            try? resume.write(to: resumeDataURL(itemID, 0), options: .atomic)
            item.receivedBytes = max(item.receivedBytes, Self.resumedBytes(in: resume))
            trace("dl-blob", [("item", itemID), ("bytes", Self.resumedBytes(in: resume))])
        }
        // Every non-cancellation transfer error, always (not trace-gated) — the code is what
        // distinguishes a daemon refusal from a server problem from a bad resume blob.
        RemoteLog.shared.event("dl-err", [
            ("item", itemID), ("code", code), ("bytes", item.receivedBytes),
            ("bg", inBackground ? 1 : 0), ("msg", String(message.prefix(60)))])
        partCensus(item, "err-\(code)")
        reconcileDurableParts(item)

        // -3000 at the END of a complete transfer is almost always the device being out of room: iOS
        // could not move the finished file into our container. Restarting from zero cannot fix that and
        // costs another full download, so name the real problem instead.
        if code == NSURLErrorCannotCreateFile {
            let free = availableBytesStrict()
            RemoteLog.shared.event("dl-space", [
                ("item", itemID), ("strict", free), ("lenient", availableBytes()),
                ("total", item.totalBytes), ("got", item.receivedBytes), ("why", "err-3000")])
            stagingCensus("err-3000")
            probeDeliveryPath("err-3000")
            // DEVICE-MEASURED 2026-07-25 (v1.0.326 traces): the hand-over is broken at EVERY size on
            // this device. A 64 MB slice — the FIRST one, nothing durable yet — fails exactly like a
            // 1.6 GB whole file, with 4.9 GB strict free and no underlying error. Five retries in a row
            // failed in 5 seconds flat while strict free fell 472 MB (~70 MB each — one slice's worth,
            // stranded and never returned). That much is solid, and it is the "System Data" growth.
            //
            // NOT established, despite an earlier comment here claiming it: WHERE those bytes go. That
            // claim rested on `dl-staging` reading `files=0 bytes=0`, from a census that counted only
            // non-empty regular FILES — so an absent delivery directory and an empty one were
            // indistinguishable, and "the daemon stages outside our container" was never measured at
            // all. `probeDeliveryPath` now tests the actual directory the daemon must write into.
            //
            // What DOES follow: a -3000 with nothing durable is not a transient to retry. Whatever the
            // cause, the attempt cannot deliver and each one strands another slice. Give up on the
            // daemon: this tracks the device/OS rather than one file, so the verdict persists (Settings →
            // Diagnostics → Re-test System Transfers clears it) and later downloads go in-process.
            if fileSize(partURL(itemID, 0)) == 0, !daemonHandoverBroken {
                daemonHandoverBroken = true
                RemoteLog.shared.event("dl-daemon-broken", [
                    ("item", itemID), ("strict", free), ("total", item.totalBytes)])
            }
            // Not even one copy fits: the in-process fallback would fail too, so say so and stop
            // rather than spending another few gigabytes proving it.
            if item.totalBytes > 0, free > 0, free < item.totalBytes {
                item.state = .failed
                item.error = "Not enough space to save this download — "
                    + "\(Self.bytesLabel(free)) free, needs \(Self.bytesLabel(item.totalBytes))."
                cancelTasks(item, produceResumeData: false)
                cleanupParts(itemID)
                syncLiveActivity()
                return
            }
        }
        // The system refused to hand the file over. Retry within a budget sized to what a retry COSTS
        // (see below), then switch to the in-process transport, which writes every chunk into our own
        // file and so never performs the hand-over step that is failing.
        let deliveryFailure = code == NSURLErrorCannotCreateFile || code == NSURLErrorCannotWriteToFile
            || code == NSURLErrorBadServerResponse
        // A server that cannot serve ranges refuses the FIRST one, so a refusal with nothing durable yet
        // is a genuine capability signal; later ones are proxies, 416s and transients (which must never
        // downgrade a server that has already served slices). Whole-file is then the only option.
        if code == NSURLErrorBadServerResponse, fileSize(partURL(itemID, 0)) == 0,
           !sliceUnsupported.contains(itemID) {
            sliceUnsupported.insert(itemID)
            resumeData[itemID]?[0] = nil          // a range blob is meaningless to a whole-file task
            clearResumeFiles(itemID)
            RemoteLog.shared.event("dl-no-range", [("item", itemID)])
        }
        if deliveryFailure {
            let attempt = fileRecoveryAttempts[itemID] ?? 0
            fileRecoveryAttempts[itemID, default: 0] += 1
            // Failing at ~100% IS the hand-over step: the bytes all arrived and only the final move
            // failed, so retrying the daemon is guaranteed to repeat it.
            let transferredEverything = item.totalBytes > 0
                && item.receivedBytes >= Int64(Double(item.totalBytes) * 0.9)
            // Retrying a WHOLE-FILE transfer that already moved everything simply repeats the hand-over
            // at the cost of the entire file again, so it gets none. A SLICE costs at most one slice —
            // its predecessors are already banked — so it gets a real budget before we surrender the
            // only transport that runs while the app is suspended. Successful slices reset the count,
            // so this bounds CONSECUTIVE failures, not failures over the whole file.
            // Once the daemon has proven it cannot hand a file over, its retry budget is ZERO — a retry
            // cannot succeed and costs another stranded slice. Otherwise the budget is sized to what a
            // retry costs.
            let budget = daemonHandoverBroken && engine == .background
                ? 0 : (ranged ? 4 : (transferredEverything ? 0 : 1))
            if attempt < budget {
                trace("dl-retry", [("item", itemID), ("code", code), ("try", attempt + 1),
                                   ("blob", resumeData[itemID]?[0] != nil ? 1 : 0)])
                // Stay on whichever transport this item is on — an item already demoted to the
                // in-process fallback must never be handed back to the daemon that failed it.
                if foregroundFallback.contains(itemID) { startForegroundFallback(item) }
                else { startBackgroundTransfer(item) } // reuses the blob when one was banked above
                syncLiveActivity()
                return
            }
            // Nothing left to escalate TO once we are already on the fallback: fall through and let the
            // transient/terminal handling below decide, rather than restarting it in a loop.
            if attempt <= budget, !foregroundFallback.contains(itemID) {
                RemoteLog.shared.event("dl-fallback", [
                    ("item", itemID), ("code", code), ("bytes", item.receivedBytes)])
                foregroundFallback.insert(itemID)
                item.transcodeStatus = ""
                releaseResumeBlob(itemID)   // the daemon's own partial is unreachable — let it drop it
                // Only a WHOLE-FILE daemon transfer leaves us with nothing: it holds every byte in a temp
                // file we can't reach, so the part is empty and the fallback has to start over. A sliced
                // transfer has already committed each landed slice into our own part — resuming from it
                // is the entire reason for slicing, so never wipe it here.
                let durable = fileSize(partURL(itemID, 0))
                if durable > 0 {
                    item.receivedBytes = durable
                    for i in item.connections.indices { item.connections[i].received = durable }
                } else {
                    cleanupParts(itemID)
                    item.receivedBytes = 0
                    for i in item.connections.indices { item.connections[i].received = 0 }
                }
                startForegroundFallback(item)
                syncLiveActivity()
                return
            }
        }

        let retries = networkRetries[itemID] ?? 0
        if Self.transientNetworkCodes.contains(code) && retries < maxNetworkRetries {
            // Wait for the connection to come back. The iOS resume blob captured on cancel carries the
            // daemon's own offset, so resuming continues rather than restarting.
            item.state = .waitingForNetwork
            item.error = nil
            cancelTasks(item, produceResumeData: false)   // the blob came off the error above
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
                guard let inf = snap.info[taskID], inf.item == item.id else { continue }
                if inf.conn < item.connections.count { item.connections[inf.conn].received = bytes }
            }
            let sum = item.connections.reduce(Int64(0)) { $0 + $1.received }
            let combined = sum
            let now = Date()
            let dt = now.timeIntervalSince(item.lastSampleTime)
            if dt > 0.3 {
                item.speed = max(0, Double(combined - item.lastSampleBytes) / dt)
                item.lastSampleBytes = combined
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
            // Never relaunch across a live drain: the barrier's completion restarts the engine itself,
            // with part sizes that are settled. A path flap can fire milliseconds after the cancellations.
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
                    bitRate: f?.bit_rate, totalBytes: 0, scene: scene, apiKey: sidecar.apiKey,
                    localThumb: {
                        let t = metaDir.appendingPathComponent("\(id)-thumb.jpg")
                        return FileManager.default.fileExists(atPath: t.path) ? t : nil
                    }())
                item.companionCodec = codec
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
                    bitRate: f?.bit_rate, totalBytes: 0, scene: scene, apiKey: sidecar.apiKey,
                    localThumb: {
                        let t = metaDir.appendingPathComponent("\(id)-thumb.jpg")
                        return FileManager.default.fileExists(atPath: t.path) ? t : nil
                    }())
                item.companionCodec = codec
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
            let base = ((file?.basename ?? scene.title ?? "video") as NSString).deletingPathExtension
            let ext = sidecar.downloadExt ?? (scene.fileContainer.isEmpty ? "mp4" : scene.fileContainer)
            let thumb = metaDir.appendingPathComponent("\(id)-thumb.jpg")
            let item = DownloadItem(
                id: id, title: scene.title ?? base, url: fileURL,
                fileName: base, ext: ext, codec: file?.video_codec,
                width: file?.width, height: file?.height, bitRate: file?.bit_rate,
                totalBytes: total, scene: scene, apiKey: sidecar.apiKey,
                localThumb: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil
            )
            // A delivered part means the transfer finished while we were dead; otherwise the daemon
            // holds the bytes in its own temp file and the resume blob is what carries them forward.
            let sum = Int64((try? partURL(id, 0).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            item.connections[0].received = sum
            if item.connections[0].total > 0, sum >= item.connections[0].total {
                finished[id, default: []].insert(0)
            }
            if let data = try? Data(contentsOf: resumeDataURL(id, 0)) {
                resumeData[id, default: [:]][0] = data
            }
            item.receivedBytes = sum
            item.state = .paused   // reconnectTasks() flips this to .downloading if a live task is found
            items.append(item)
            // Always logged: what actually survived to this launch is the ground truth a "it restarted"
            // report has to be checked against.
            let pct: Int? = total > 0 ? Int(Double(sum) / Double(total) * 100) : nil
            RemoteLog.shared.event("dl-restore", [
                ("item", id), ("bytes", sum), ("total", total), ("pct", pct),
                ("blob", resumeData[id]?[0] != nil ? 1 : 0),
                ("done", (finished[id] ?? []).count)])
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
            let expected = parts.count >= 6
                ? (Int64(parts[5]) ?? item.connections[conn].total) : item.connections[conn].total
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
        }
        restoringTasks = false
        resumeInterruptedDownloads()
        syncLiveActivity()
    }

    /// Continue anything that was mid-transfer when the app died and has no live task to re-attach to.
    /// Without this a download interrupted by a kill (or a connection drop the daemon gave up on) sits
    /// `.paused` on the Downloads screen until the user notices and taps resume — the opposite of
    /// "keeps going while the app is closed". A download the USER paused is left alone.
    private func resumeInterruptedDownloads() {
        for item in items where item.state == .paused && backgroundTasks[item.id] == nil {
            guard FileManager.default.fileExists(atPath: activeURL(item.id).path),
                  !FileManager.default.fileExists(atPath: userPausedURL(item.id).path) else { continue }
            trace("dl-auto-resume", [("item", item.id), ("bytes", item.receivedBytes)])
            launch(item, reset: false)
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

    /// Carry in-flight part files across the Caches → Application Support move (v1.0.307) so an upgrade
    /// mid-download resumes instead of restarting. Best-effort and idempotent: anything already present at
    /// the destination wins, and the old directory is removed once drained.
    nonisolated private static func migrateLegacyParts(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let dest = new.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: file); continue }
            try? fm.moveItem(at: file, to: dest)
        }
        try? fm.removeItem(at: old)
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
    /// Hand a resume blob back to the system so it releases the partial file behind it.
    ///
    /// A blob is a POINTER to a partially-downloaded file the download daemon is holding for you, in
    /// its own cache — outside the app sandbox, where it lands in iOS's "System Data". Dropping the
    /// blob (`resumeData[id] = nil`) orphans that file: the app can no longer reach it and the system
    /// has no idea we're finished with it. Repeated across a run of failed multi-GB downloads that is
    /// tens of gigabytes of invisible, unreclaimable storage — and, because it eats real free space,
    /// the direct cause of the next download failing. Materialising a task from the blob and
    /// cancelling it WITHOUT asking for new resume data is what tells the daemon to let go.
    private func releaseResumeBlob(_ itemID: String) {
        let blob = resumeData[itemID]?[0] ?? (try? Data(contentsOf: resumeDataURL(itemID, 0)))
        resumeData[itemID] = nil
        try? FileManager.default.removeItem(at: resumeDataURL(itemID, 0))
        guard let blob, !blob.isEmpty else { return }
        let task = bgSession.downloadTask(withResumeData: blob)
        task.cancel()
        trace("dl-blob-release", [("item", itemID), ("bytes", Self.resumedBytes(in: blob))])
    }

    /// Make iOS actually hand over the space it claims is available.
    ///
    /// `volumeAvailableCapacityForImportantUsage` promises space that INCLUDES purgeable caches — it
    /// read 40 GB on this device while only 6 GB was genuinely free — but the system reclaims those
    /// caches under real allocation pressure, and a background download asking the daemon for room
    /// evidently does not count. Preallocating a file of the required size IS that pressure:
    /// `F_PREALLOCATE` with `F_ALLOCATEALL` reserves real blocks (not a sparse hole), which forces the
    /// purge, and the freed space remains available for the transfer that follows.
    ///
    /// Best-effort by design: on failure the download proceeds exactly as before.
    @discardableResult
    private func reserveSpace(_ bytes: Int64) -> Bool {
        guard bytes > 0 else { return false }
        let fm = FileManager.default
        let probe = partsDir.appendingPathComponent(".space-probe")
        try? fm.removeItem(at: probe)
        try? fm.createDirectory(at: partsDir, withIntermediateDirectories: true)
        guard fm.createFile(atPath: probe.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: probe.path) else { return false }
        var request = fstore_t(fst_flags: UInt32(F_ALLOCATEALL),
                               fst_posmode: F_PEOFPOSMODE,
                               fst_offset: 0,
                               fst_length: off_t(bytes),
                               fst_bytesalloc: 0)
        let allocated = fcntl(handle.fileDescriptor, F_PREALLOCATE, &request) != -1
        try? handle.close()
        try? fm.removeItem(at: probe)
        RemoteLog.shared.event("dl-reserve", [
            ("need", bytes), ("ok", allocated ? 1 : 0), ("after", availableBytesStrict())])
        return allocated
    }

    /// Reclaim everything a run of failed transfers can strand.
    ///
    /// Releasing resume blobs only works while we still HOLD the blob — once discarded, the partial
    /// file it pointed at is orphaned and no API can name it. Fortunately those files are not beyond
    /// reach: the background daemon stages them inside OUR OWN container, under
    /// `Library/Caches/com.apple.nsurlsessiond/`. iOS treats that as purgeable (which is exactly why
    /// `…ForImportantUsage` counts it as free and reads 40 GB on a 4 GB-free phone) but only actually
    /// reclaims it under pressure, so a run of failed multi-GB downloads sits there indefinitely as
    /// "System Data". With no live tasks it is safe for us to delete directly.
    /// Clear the "the system can't hand files over on this device" verdict so the next transfer tries the
    /// background service again. Exposed because the verdict is deliberately sticky: an iOS update could
    /// fix the hand-over, and capturing diagnostics requires being able to reproduce the failure.
    func retestSystemTransfers() {
        daemonHandoverBroken = false
        foregroundFallback.removeAll()
        fileRecoveryAttempts.removeAll()
        RemoteLog.shared.event("dl-retest", [("bundle", Bundle.main.bundleIdentifier)])
        probeDeliveryPath("retest")
    }

    func reclaimTransferStorage() {
        let before = availableBytesStrict()
        let fm = FileManager.default
        let live = Set(items.filter { $0.state != .completed && $0.state != .stopped }.map(\.id))
        var blobs = 0
        if let files = try? fm.contentsOfDirectory(at: partsDir, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "resume" {
                let name = url.deletingPathExtension().lastPathComponent   // "<itemID>-<conn>"
                guard let dash = name.lastIndex(of: "-") else { continue }
                let id = String(name[name.startIndex..<dash])
                guard !live.contains(id) else { continue }
                releaseResumeBlob(id)
                blobs += 1
            }
        }
        sweepOrphanedParts()
        let busy = items.contains { $0.state == .downloading || $0.state == .waitingForNetwork }
        let handler: @Sendable ([URLSessionTask]) -> Void = { [weak self] tasks in
            let box = UncheckedSendableBox(tasks)
            Task { @MainActor in
                guard let self else { return }
                var cancelled = 0
                for task in box.value {
                    let owner = task.taskDescription?.components(separatedBy: "\u{1}").first ?? ""
                    guard !live.contains(owner) else { continue }
                    task.cancel()
                    cancelled += 1
                }
                // Only sweep the daemon's staging area when nothing is in flight — deleting a file it
                // is actively writing would break a live download.
                let staged = (busy || !box.value.isEmpty) ? 0 : self.purgeSessionStagingArea()
                RemoteLog.shared.event("dl-reclaim", [
                    ("before", before), ("after", self.availableBytesStrict()),
                    ("blobs", blobs), ("tasks", cancelled), ("staged", staged),
                    ("skipped", (busy || !box.value.isEmpty) ? 1 : nil)])
            }
        }
        bgSession.getAllTasks(completionHandler: handler)
    }

    /// Size up the background daemon's staging area (inside our own container, under
    /// `Library/Caches/com.apple.nsurlsessiond`). Purely diagnostic: -3000 arrives with no underlying
    /// error and no path, so the only way to test "iOS purged the staging file mid-transfer" is to look
    /// at what is there when the failure lands.
    private func stagingCensus(_ why: String) {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let staging = caches.appendingPathComponent("com.apple.nsurlsessiond", isDirectory: true)
        var bytes: Int64 = 0
        var files = 0
        var dirs = 0
        var names: [String] = []
        // Count DIRECTORIES and zero-byte entries too. The original filtered on `size > 0`, which meant
        // an absent delivery directory and an empty one produced the identical `files=0 bytes=0` reading
        // — and that reading is what wrongly convinced an earlier session the daemon stages outside our
        // container. A census that cannot tell "nothing here" from "nothing to see" is not a measurement.
        if let walker = fm.enumerator(at: staging, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                      options: [], errorHandler: nil) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values?.isDirectory == true { dirs += 1 } else {
                    files += 1
                    bytes += Int64(values?.fileSize ?? 0)
                }
                if names.count < 12 { names.append(url.lastPathComponent) }
            }
        }
        let listing: String? = names.isEmpty ? nil : names.joined(separator: ",")
        RemoteLog.shared.event("dl-staging", [
            ("why", why), ("exists", fm.fileExists(atPath: staging.path) ? 1 : 0),
            ("dirs", dirs), ("files", files), ("bytes", bytes), ("names", listing)])
    }

    /// Probe the exact directory the background daemon must create the delivered file in, and prove
    /// whether WE can create and write there ourselves.
    ///
    /// The hand-over is the only step of the transfer the app doesn't perform, and it is the one step
    /// never actually measured — every previous conclusion about it was inferred from an error iOS
    /// attaches nothing to. This walks the daemon's delivery path level by level, then tries the two
    /// operations the daemon itself must perform (create the directory, write a file into it) and
    /// reports exactly which one fails and with what errno. If our own process can do both, the failure
    /// is about WHO is asking, not about the path. If it can't, the error names the real problem.
    private func probeDeliveryPath(_ why: String) {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let root = caches.appendingPathComponent("com.apple.nsurlsessiond", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let mine = downloads.appendingPathComponent(bundleID, isDirectory: true)

        var createError: String?
        do { try fm.createDirectory(at: mine, withIntermediateDirectories: true) }
        catch { let e = error as NSError; createError = "\(e.domain):\(e.code)" }

        var writeError: String?
        let probe = mine.appendingPathComponent("stashy-probe.tmp")
        do {
            try Data([0x1]).write(to: probe, options: .atomic)
            try fm.removeItem(at: probe)
        } catch { let e = error as NSError; writeError = "\(e.domain):\(e.code)" }

        RemoteLog.shared.event("dl-probe", [
            ("why", why), ("bundle", bundleID),
            ("root", fm.fileExists(atPath: root.path) ? 1 : 0),
            ("downloads", fm.fileExists(atPath: downloads.path) ? 1 : 0),
            ("mine", fm.fileExists(atPath: mine.path) ? 1 : 0),
            ("mkdir", createError ?? "ok"), ("write", writeError ?? "ok")])
    }

    /// Delete the background daemon's staging directory inside our container and return the bytes
    /// recovered. Caller must have established that no transfer is in flight.
    private func purgeSessionStagingArea() -> Int64 {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let staging = caches.appendingPathComponent("com.apple.nsurlsessiond", isDirectory: true)
        guard let walker = fm.enumerator(at: staging, includingPropertiesForKeys: [.fileSizeKey],
                                         options: [], errorHandler: nil) else { return 0 }
        var found: Int64 = 0
        var victims: [URL] = []
        for case let url as URL in walker {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size > 0 { found += size; victims.append(url) }
        }
        guard found > 0 else { return 0 }
        for url in victims { try? fm.removeItem(at: url) }
        RemoteLog.shared.event("dl-staging-purge", [("bytes", found), ("files", victims.count)])
        return found
    }

    /// Real free space, for the Diagnostics readout — iOS's own Settings figure counts purgeable
    /// caches and can read tens of gigabytes higher than what a download can actually use.
    var freeSpaceLabel: String { Self.bytesLabel(availableBytesStrict()) }

    private func clearResumeFiles(_ itemID: String) {
        try? FileManager.default.removeItem(at: resumeDataURL(itemID, 0))
    }
    private func cleanupParts(_ itemID: String) {
        // Enumerate rather than guess at indices: earlier builds wrote eight segments plus a "999"
        // shadow part, and anything missed here is stranded on disk forever now that parts live
        // outside the purgeable Caches directory.
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: partsDir, includingPropertiesForKeys: nil) {
            for url in files where url.lastPathComponent.hasPrefix("\(itemID)-") {
                try? fm.removeItem(at: url)
            }
        }
        finished[itemID] = nil
        resumeData[itemID] = nil
    }
    private func cleanupMeta(_ itemID: String) {
        for name in ["\(itemID).json", "\(itemID)-thumb.jpg", "\(itemID)-sprite.jpg", "\(itemID).vtt",
                     "\(itemID).active", "\(itemID).userpaused"] {
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
    /// Written only by an explicit user pause, so a relaunch can distinguish it from an interruption.
    private func userPausedURL(_ itemID: String) -> URL { metaDir.appendingPathComponent("\(itemID).userpaused") }
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
                totalBytes: size,
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
