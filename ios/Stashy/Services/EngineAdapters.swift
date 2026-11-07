import AVFoundation
import UIKit
import os
import VideoEngine
import VideoToolbox

// The app side of `nphil/stashy-videoengine` (product `VideoEngine`, pinned with `exactVersion` in
// ios/project.yml). The engine owns remux, transcode, hardware facts and diagnostics; this file maps
// Stashy's settings, logging and server auth onto it. See the engine's docs/ENGINE.md.

// MARK: - Transcode presets (the Downloads sheet)

/// Target long-edge resolution for an on-device transcode. `original` keeps the source dimensions.
enum TranscodeResolution: String, CaseIterable, Identifiable, Codable {
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
    /// Nominal output HEIGHT for this rung (nil = keep source), used to key the VMAF bitrate map — which is
    /// keyed by output height. Exact for 16:9 landscape; other aspects just miss the map and fall back.
    var nominalHeight: Int? {
        switch self {
        case .original: return nil
        case .uhd2160: return 2160
        case .fhd1080: return 1080
        case .hd720: return 720
        case .sd480: return 480
        }
    }
}

enum TranscodeQuality: String, CaseIterable, Identifiable, Codable {
    case low, medium, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var engine: TranscodeSettings.Quality {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

enum TranscodeCodec: String, CaseIterable, Identifiable, Codable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
    var engine: TranscodeSettings.Codec { self == .hevc ? .hevc : .h264 }
}

/// One on-device transcode as the user chose it. Persisted as `settings.json` in the item's work dir so a
/// killed transcode resumes after relaunch — the field names are that file's format, keep them.
struct OnDeviceTranscodeSettings: Codable {
    var resolution: TranscodeResolution
    var quality: TranscodeQuality
    var codec: TranscodeCodec
    /// Absolute target video bitrate (bits/sec) from the server's VMAF map, overriding the preset
    /// bitrate ladder. Optional (nil ⇒ use the ladder). HEVC-calibrated — only set for HEVC encodes.
    var bitrateOverride: Int? = nil

    var engine: TranscodeSettings {
        TranscodeSettings(codec: codec.engine, quality: quality.engine,
                          maxLongEdge: resolution.maxDimension, bitrateOverride: bitrateOverride)
    }

    /// Identifies a chunk plan. Same spelling the app's own chunked transcoder used, so a transcode
    /// interrupted before the engine switch resumes instead of starting over.
    var planKey: String { "\(resolution.rawValue)-\(quality.rawValue)-\(codec.rawValue)" }
}

// MARK: - Logging

extension EngineLogger {
    /// Engine events into the opt-in debug stream (no-op while RemoteLog is off).
    static let remoteLog = EngineLogger(
        event: { tag, fields in RemoteLog.shared.event(tag, fields.map { ($0.0, $0.1 as Any?) }) },
        message: { RemoteLog.shared.log($0) }
    )
}

// MARK: - Hardware

/// The engine's device snapshot, taken once at launch. Routing reads it synchronously from any thread.
enum EngineHardware {
    private static let latest = OSAllocatedUnfairLock<HardwareCapabilities?>(initialState: nil)

    static let provider = LiveHardwareCapabilityProvider(display: { await currentDisplay() })

    /// Take a snapshot (records the `hw-*` lines in the engine report) and keep it for routing.
    static func refresh() async {
        let snapshot = await provider.snapshot()
        latest.withLock { $0 = snapshot }
    }

    /// True when AVPlayer decodes AV1 in hardware (A17 Pro and later), so AV1 remuxes on-device instead of
    /// asking the server to transcode. Reads the device directly if the launch snapshot hasn't landed.
    static var av1HardwareDecode: Bool {
        if let snapshot = latest.withLock({ $0 }) { return snapshot.decode.av1 == .hardware }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }

    /// `EngineDiagnostics.report()` after a fresh snapshot, for Settings → Diagnostics.
    static func report() async -> String {
        await refresh()
        return EngineDiagnostics.report()
    }

    @MainActor
    private static func currentDisplay() -> HardwareCapabilities.Display {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?.screen
        guard let screen else { return HardwareCapabilities.Display(hdrPlaybackEligible: AVPlayer.eligibleForHDRPlayback) }
        return HardwareCapabilities.Display(
            hdrPlaybackEligible: AVPlayer.eligibleForHDRPlayback,
            edrHeadroomPotential: Double(screen.potentialEDRHeadroom),
            edrHeadroomCurrent: Double(screen.currentEDRHeadroom),
            maxFramesPerSecond: screen.maximumFramesPerSecond,
            wideGamut: screen.traitCollection.displayGamut == .P3,
            capturing: screen.traitCollection.sceneCaptureState == .active,
            externalPlaybackActive: UIScreen.screens.count > 1
        )
    }
}

// MARK: - Remux

extension RemuxSession {
    /// A remux of a Stash stream URL or a downloaded file. Stash URLs carry the API key as `?apikey=`; the
    /// engine sends it as the `ApiKey` header instead (Stash accepts either), so it never sits in a URL.
    static func stash(source: URL) -> RemuxSession {
        var url = source
        var headers: [String: String] = [:]
        if !source.isFileURL, var parts = URLComponents(url: source, resolvingAgainstBaseURL: false) {
            let items = parts.queryItems ?? []
            if let key = items.first(where: { $0.name == "apikey" })?.value, !key.isEmpty {
                headers["ApiKey"] = key
                let rest = items.filter { $0.name != "apikey" }
                parts.queryItems = rest.isEmpty ? nil : rest
                url = parts.url ?? source
            }
        }
        return RemuxSession(url: url, headers: headers, logger: .remoteLog)
    }
}
