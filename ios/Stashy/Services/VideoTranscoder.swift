import AVFoundation

/// Target long-edge resolution for an on-device transcode. `original` keeps the source dimensions.
enum TranscodeResolution: String, CaseIterable, Identifiable {
    case original, uhd2160, fhd1080, hd720, sd480
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Original"
        case .uhd2160: return "2160p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        }
    }
    /// Longest-edge pixel cap (nil = keep source).
    var maxDimension: Int? {
        switch self {
        case .original: return nil
        case .uhd2160: return 3840
        case .fhd1080: return 1920
        case .hd720: return 1280
        case .sd480: return 854
        }
    }
}

enum TranscodeQuality: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Approximate megabits/sec per megapixel at 30 fps for H.264 (HEVC scaled down separately).
    var mbpsPerMegapixel: Double {
        switch self {
        case .low: return 2.0
        case .medium: return 4.0
        case .high: return 7.0
        }
    }
}

enum TranscodeCodec: String, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
    var codecType: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
    /// HEVC reaches similar quality at a lower bitrate than H.264.
    var bitrateFactor: Double { self == .hevc ? 0.6 : 1.0 }
}

/// On-device re-encode of a local video file to a chosen resolution / quality / codec, via
/// `AVAssetReader` → `AVAssetWriter` (hardware VideoToolbox encode). Produces a faststart MP4. Used to
/// shrink a downloaded offline copy for space, or to normalise it to an iPhone-native codec.
///
/// Reads/writes only files AVFoundation can decode (H.264 / HEVC in mp4/mov/m4v, etc.). Exotic containers
/// FFmpeg-only formats (MKV/WebM/VP9/AV1) will throw `.unreadable` — a future FFmpeg-based path can cover
/// those.
final class VideoTranscoder: @unchecked Sendable {
    enum TranscodeError: LocalizedError {
        case unreadable, noVideo, readFailed, writeFailed, cancelled
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This video's format can't be transcoded on-device yet."
            case .noVideo: return "No video track found."
            case .readFailed: return "Couldn't read the source video."
            case .writeFailed: return "Couldn't write the transcoded video."
            case .cancelled: return "Cancelled."
            }
        }
    }

    struct Settings {
        var resolution: TranscodeResolution
        var quality: TranscodeQuality
        var codec: TranscodeCodec
    }

    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }

    /// Transcode `input` → `output`. `onProgress` is called (0…1) off the main actor as video packets are
    /// written. Throws on failure/cancel; the caller removes a partial `output`.
    func run(input: URL, output: URL, settings: Settings,
             onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        // Fail fast + clearly on containers AVFoundation can't demux (MKV/WebM etc.): otherwise
        // loadTracks just returns empty and the user sees a vague "no video track". These need the
        // FFmpeg-based path (not yet wired for transcode).
        guard (try? await asset.load(.isReadable)) == true else { throw TranscodeError.unreadable }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let videoTrack = videoTracks.first else { throw TranscodeError.noVideo }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let duration = (try? await asset.load(.duration)) ?? .zero
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30

        let size = Self.outputSize(naturalSize: naturalSize, maxDimension: settings.resolution.maxDimension)
        let bitrate = Self.videoBitrate(width: size.width, height: size.height, fps: fps,
                                        quality: settings.quality, codec: settings.codec)

        guard let reader = try? AVAssetReader(asset: asset) else { throw TranscodeError.unreadable }
        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { throw TranscodeError.writeFailed }
        writer.shouldOptimizeForNetworkUse = true   // faststart (moov up front)

        // --- Video: decode to 4:2:0 buffers, encode to the target codec/size/bitrate ---
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw TranscodeError.unreadable }
        reader.add(videoOut)

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec.codecType,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())
            ]
        ])
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform   // keep display orientation; the encoder scales to width/height
        guard writer.canAdd(videoIn) else { throw TranscodeError.writeFailed }
        writer.add(videoIn)

        // --- Audio (if present): decode to PCM, encode to AAC ---
        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if let audioTrack {
            let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            aOut.alwaysCopiesSampleData = false
            if reader.canAdd(aOut) {
                reader.add(aOut)
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44_100,
                    AVEncoderBitRateKey: 160_000
                ])
                aIn.expectsMediaDataInRealTime = false
                if writer.canAdd(aIn) { writer.add(aIn); audioOut = aOut; audioIn = aIn }
            }
        }

        guard reader.startReading() else { throw reader.error ?? TranscodeError.readFailed }
        guard writer.startWriting() else { throw writer.error ?? TranscodeError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(duration.seconds, 0.1)

        try await withThrowingTaskGroup(of: Void.self) { group in
            let v = UncheckedTranscodeBox((videoIn, videoOut))
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.pump(v.value.0, v.value.1, totalSeconds: totalSeconds, onProgress: onProgress)
            }
            if let audioIn, let audioOut {
                let a = UncheckedTranscodeBox((audioIn, audioOut))
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.pump(a.value.0, a.value.1, totalSeconds: totalSeconds, onProgress: nil)
                }
            }
            try await group.waitForAll()
        }

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw TranscodeError.cancelled
        }
        if reader.status == .failed { throw reader.error ?? TranscodeError.readFailed }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TranscodeError.writeFailed }
    }

    /// Drain one reader track into one writer input, appending samples whenever the input is ready.
    private func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderTrackOutput,
                      totalSeconds: Double, onProgress: (@Sendable (Double) -> Void)?) async throws {
        let box = UncheckedTranscodeBox((input, output))
        let queue = DispatchQueue(label: "stashy.transcode.pump")
        // Throttle state. The `requestMediaDataWhenReady` block is @Sendable, so it can't capture and
        // mutate plain locals — hold the state in a reference box it captures by reference. Only ever
        // touched from `queue` (serial, single writer), so @unchecked Sendable is honest. Without the
        // throttle a video pump at HW transcode speed calls onProgress per frame (100–500+/sec), each
        // spawning a MainActor Task + animated re-render; here we report only on meaningful movement.
        final class ProgressThrottle: @unchecked Sendable {
            var lastProgress: Double = -1
            var lastTime = Date.distantPast
        }
        let throttle = ProgressThrottle()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.value.0.requestMediaDataWhenReady(on: queue) { [weak self] in
                let (input, output) = box.value
                while input.isReadyForMoreMediaData {
                    if self?.isCancelled == true { input.markAsFinished(); cont.resume(); return }
                    if let sample = output.copyNextSampleBuffer() {
                        if let onProgress {
                            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            if t.isFinite, t >= 0 {
                                let p = min(1, t / totalSeconds)
                                let now = Date()
                                if p - throttle.lastProgress >= 0.005 || now.timeIntervalSince(throttle.lastTime) >= 0.1 {
                                    throttle.lastProgress = p
                                    throttle.lastTime = now
                                    onProgress(p)
                                }
                            }
                        }
                        if !input.append(sample) {
                            input.markAsFinished()
                            cont.resume(throwing: TranscodeError.writeFailed)
                            return
                        }
                    } else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }

    // MARK: - Sizing / bitrate

    /// Output pixel size for a long-edge cap, preserving aspect and forcing even dimensions (required by
    /// the encoders). Orientation is carried by the writer input's transform, so this works on the
    /// storage-oriented `naturalSize` directly.
    static func outputSize(naturalSize: CGSize, maxDimension: Int?) -> (width: Int, height: Int) {
        var w = abs(naturalSize.width), h = abs(naturalSize.height)
        if w < 2 || h < 2 { return (1280, 720) }
        if let maxDim = maxDimension.map(CGFloat.init) {
            let longEdge = max(w, h)
            if longEdge > maxDim {
                let scale = maxDim / longEdge
                w *= scale; h *= scale
            }
        }
        return (max(2, Int((w / 2).rounded()) * 2), max(2, Int((h / 2).rounded()) * 2))
    }

    static func videoBitrate(width: Int, height: Int, fps: Double,
                             quality: TranscodeQuality, codec: TranscodeCodec) -> Int {
        let megapixels = Double(width * height) / 1_000_000
        let mbps = quality.mbpsPerMegapixel * megapixels * (fps / 30) * codec.bitrateFactor
        let bits = mbps * 1_000_000
        return max(500_000, Int(bits))
    }
}

/// Ferries non-Sendable AVFoundation reader/writer objects into the `@Sendable` transcode closures; safe
/// because each object is only ever touched on its own single pump queue.
private struct UncheckedTranscodeBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
