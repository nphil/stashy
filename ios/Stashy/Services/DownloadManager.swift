import SwiftUI
import Network
import Observation

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
    let ext: String
    let codec: String?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let totalBytes: Int64

    var state: DownloadState = .queued
    var connections: [DownloadConnection]
    var receivedBytes: Int64 = 0
    var speed: Double = 0            // bytes/sec, smoothed by the poll loop
    var error: String?
    var localURL: URL?

    @ObservationIgnored var lastSampleBytes: Int64 = 0
    @ObservationIgnored var lastSampleTime = Date()

    var progress: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }

    var resolutionLabel: String? { height.map { "\($0)p" } }
    var codecLabel: String? { codec?.uppercased() }
    var bitrateLabel: String? {
        guard let b = bitRate, b > 0 else { return nil }
        return String(format: "%.1f Mbps", Double(b) / 1_000_000)
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
         codec: String?, width: Int?, height: Int?, bitRate: Int?, totalBytes: Int64, connectionCount: Int) {
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
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let store: TransferStore
    let onFinish: @Sendable (String, Int) -> Void
    let onError: @Sendable (String, String) -> Void

    init(store: TransferStore,
         onFinish: @escaping @Sendable (String, Int) -> Void,
         onError: @escaping @Sendable (String, String) -> Void) {
        self.store = store
        self.onFinish = onFinish
        self.onError = onError
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        store.setReceived(task: downloadTask.taskIdentifier, totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = store.info(task: downloadTask.taskIdentifier) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: info.part)
        try? fm.moveItem(at: location, to: info.part)
        store.drop(task: downloadTask.taskIdentifier)
        onFinish(info.item, info.conn)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }                            // success handled by didFinishDownloadingTo
        if (error as NSError).code == NSURLErrorCancelled { return }   // pause/stop
        let info = store.info(task: task.taskIdentifier)
        store.drop(task: task.taskIdentifier)
        if let info { onError(info.item, error.localizedDescription) }
    }
}

@Observable
@MainActor
final class DownloadManager {
    var items: [DownloadItem] = []

    @ObservationIgnored private let connectionCount = 8
    @ObservationIgnored private let store = TransferStore()
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var delegate: DownloadDelegate!
    @ObservationIgnored private var tasks: [String: [URLSessionDownloadTask]] = [:]
    @ObservationIgnored private var resumeData: [String: [Int: Data]] = [:]
    @ObservationIgnored private var finished: [String: Set<Int>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()

    @ObservationIgnored private let downloadsDir: URL
    @ObservationIgnored private let partsDir: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        partsDir = caches.appendingPathComponent("DownloadParts", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)

        delegate = DownloadDelegate(
            store: store,
            onFinish: { [weak self] item, conn in Task { @MainActor in self?.connectionFinished(itemID: item, conn: conn) } },
            onError: { [weak self] item, msg in Task { @MainActor in self?.connectionFailed(itemID: item, message: msg) } }
        )
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        loadCompleted()
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
            totalBytes: total, connectionCount: n
        )
        items.insert(item, at: 0)
        startConnections(item)
    }

    func pause(_ item: DownloadItem) { suspend(item, auto: false) }
    func resume(_ item: DownloadItem) {
        guard item.state == .paused || item.state == .waitingForNetwork || item.state == .failed else { return }
        launch(item, reset: false)
    }
    func retry(_ item: DownloadItem) { launch(item, reset: true) }

    func stop(_ item: DownloadItem) {
        cancelTasks(item, produceResumeData: false)
        item.state = .stopped
        cleanupParts(item.id)
    }

    func delete(_ item: DownloadItem) {
        cancelTasks(item, produceResumeData: false)
        if let local = item.localURL { try? FileManager.default.removeItem(at: local) }
        cleanupParts(item.id)
        items.removeAll { $0.id == item.id }
    }

    /// Called when the Downloads screen re-appears: drop rows the user stopped while away.
    func pruneStopped() { items.removeAll { $0.state == .stopped } }

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
        item.state = .downloading
        item.error = nil
        item.lastSampleTime = Date()
        item.lastSampleBytes = item.receivedBytes
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
            store.register(task: task.taskIdentifier, item: item.id, conn: i, part: partURL(item.id, i))
            newTasks.append(task)
            task.resume()
        }
        tasks[item.id] = newTasks
        resumeData[item.id] = nil
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
                    Task { @MainActor in self?.resumeData[item.id, default: [:]][conn] = data }
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

    // MARK: - Completion / merge

    private func finalizeIfComplete(_ item: DownloadItem) {
        let done = finished[item.id] ?? []
        guard done.count == item.connections.count else { return }
        item.state = .merging
        let parts = (0..<item.connections.count).map { partURL(item.id, $0) }
        let dest = downloadsDir.appendingPathComponent("\(item.id).\(item.ext)")
        Task.detached(priority: .userInitiated) {
            let ok = Self.merge(parts: parts, into: dest)
            await MainActor.run {
                if ok {
                    item.localURL = dest
                    if item.totalBytes > 0 { item.receivedBytes = item.totalBytes }
                    for i in item.connections.indices { item.connections[i].received = item.connections[i].total }
                    item.state = .completed
                } else {
                    item.error = "Couldn't assemble the file"
                    item.state = .failed
                }
                self.cleanupParts(item.id)
            }
        }
    }

    nonisolated private static func merge(parts: [URL], into dest: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        if parts.count == 1 {   // single-connection download — nothing to concatenate
            do { try fm.moveItem(at: parts[0], to: dest); return true } catch { return false }
        }
        guard fm.createFile(atPath: dest.path, contents: nil),
              let out = try? FileHandle(forWritingTo: dest) else { return false }
        defer { try? out.close() }
        for part in parts {
            guard let inHandle = try? FileHandle(forReadingFrom: part) else { return false }
            while let chunk = try? inHandle.read(upToCount: 4 << 20), !chunk.isEmpty { out.write(chunk) }
            try? inHandle.close()
        }
        return true
    }

    private func connectionFinished(itemID: String, conn: Int) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        finished[itemID, default: []].insert(conn)
        if conn < item.connections.count { item.connections[conn].received = item.connections[conn].total }
        finalizeIfComplete(item)
    }

    private func connectionFailed(itemID: String, message: String) {
        guard let item = items.first(where: { $0.id == itemID }), item.state == .downloading else { return }
        item.state = .failed
        item.error = message
        cancelTasks(item, produceResumeData: false)
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

    private func networkChanged(satisfied: Bool) {
        if satisfied {
            for item in items where item.state == .waitingForNetwork { launch(item, reset: false) }
        } else {
            for item in items where item.state == .downloading { suspend(item, auto: true) }
        }
    }

    // MARK: - Files

    private func partURL(_ itemID: String, _ conn: Int) -> URL {
        partsDir.appendingPathComponent("\(itemID)-\(conn).part")
    }
    private func cleanupParts(_ itemID: String) {
        for i in 0..<connectionCount { try? FileManager.default.removeItem(at: partURL(itemID, i)) }
        finished[itemID] = nil
    }

    /// Re-attach already-downloaded files on launch so the Downloads list survives app restarts.
    private func loadCompleted() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            let item = DownloadItem(id: id, title: url.lastPathComponent, url: url,
                                    fileName: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension,
                                    codec: nil, width: nil, height: nil, bitRate: nil, totalBytes: size, connectionCount: 1)
            item.state = .completed
            item.localURL = url
            item.receivedBytes = size
            item.connections[0].received = size
            items.append(item)
        }
    }
}
