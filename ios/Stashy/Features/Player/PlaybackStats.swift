import Foundation

/// Which backend is driving playback.
enum EngineKind {
    case avPlayer
    /// On-device FFmpeg remux/transcode feeding AVPlayer (wired up in a later phase).
    case localFFmpeg
}

/// The resolved playback decision for a scene: which URL to play, on which engine, and *why*.
/// `reason` records the exact cause when AVPlayer (and its live blur) couldn't be used — surfaced in
/// the debug Stats overlay so it's clear what to fix (or transcode) later.
struct PlaybackRoute {
    let url: URL
    let engine: EngineKind
    /// Human label for the stream kind, e.g. "Direct" or "HLS (transcoded)".
    let streamType: String
    /// Why this engine was chosen (esp. why not AVPlayer).
    let reason: String
    /// A safe alternative URL (the Stash HLS stream) to retry on if the primary engine fails — used by
    /// the `.localFFmpeg` path so a remux/loopback problem auto-recovers to server transcode.
    var fallbackURL: URL? = nil
    /// Media duration (seconds) from Stash metadata — lets the local-HLS index compute the final
    /// segment's EXTINF without decoding the whole file. 0 when unknown.
    var duration: Double = 0
    /// For a `.localFFmpeg` route: true = on-device streaming *transcode* (re-encode via
    /// `LocalTranscodeStream`) rather than a stream-copy remux. (Roadmap M-A.)
    var onDeviceTranscode: Bool = false
    /// Longest-edge cap for that transcode (nil = keep source size); used to gate on-device to ≤1080p.
    var transcodeMaxDimension: Int? = nil
}

/// Manual server-side transcode quality (the player's gear menu / M-B). `.auto` = normal routing
/// (direct/remux/etc.); the rest force the Stash HLS transcode at that resolution.
enum ServerQuality: String, CaseIterable, Identifiable, Hashable {
    case auto, original, p1080, p720, p480, p240
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .original: return "Original"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p240: return "240p"
        }
    }
    /// Stash `resolution` query value; nil = don't force (Auto = normal routing). These are Stash's
    /// `StreamingResolutionEnum` *identifiers* (verified against stashapp/stash source:
    /// graphql/schema/types/config.graphql + pkg/models/resolution.go) — the "720p"-style labels are only
    /// GraphQL doc strings and are NOT accepted by the HTTP `?resolution=` param. Max long-edge px:
    /// LOW=240, STANDARD=480, STANDARD_HD=720, FULL_HD=1080, ORIGINAL=no resize.
    var stashResolution: String? {
        switch self {
        case .auto: return nil
        case .original: return "ORIGINAL"
        case .p1080: return "FULL_HD"
        case .p720: return "STANDARD_HD"
        case .p480: return "STANDARD"
        case .p240: return "LOW"
        }
    }
}

/// How much work — and *whose* — is going into getting the current scene on screen, ordered best→worst.
/// Surfaced as a colour-coded badge on the player so it's obvious at a glance whether we're on the cheap
/// native path or leaning on the server (a workstation whose compute we treat as the last resort). The
/// SwiftUI `color` lives in an extension in `PlaybackBadges.swift` to keep this file SwiftUI-free.
enum PlaybackTier: Int {
    case direct           // AVPlayer plays the file as-is — no conversion anywhere (least work)
    case remux            // on-device container rewrite (cheap; no re-encode)
    case localTranscode   // on-device VideoToolbox re-encode (heavier, but stays on the phone)
    case server           // Stash server transcodes live — most costly (server compute)

    var label: String {
        switch self {
        case .direct: return "Direct"
        case .remux: return "Remux"
        case .localTranscode: return "Local"   // on-device transcode — short label to fit the control row
        case .server: return "Server"
        }
    }
    /// SF Symbol depicting the mechanism.
    var symbol: String {
        switch self {
        case .direct: return "bolt.fill"           // instant, no work
        case .remux: return "shippingbox.fill"     // repackage the container
        case .localTranscode: return "cpu.fill"    // the phone's chip does the work
        case .server: return "server.rack"         // the server does the work
        }
    }
}

// MARK: - Stats model

/// A single key/value row in the Stats overlay. `id` is STABLE (the label by default) so a row whose
/// value changes each second updates in place instead of being re-created — otherwise a per-second UUID
/// made SwiftUI churn every row and the panel read like a growing spam list.
struct StatLine: Identifiable {
    let id: String
    let label: String
    let value: String
    init(_ id: String? = nil, label: String, value: String) {
        self.id = id ?? label
        self.label = label
        self.value = value
    }
}

/// A titled group of stat rows (e.g. "Playback", "Media", "Network", "Transcode"). Identified by title.
struct StatSection: Identifiable {
    var id: String { title }
    let title: String
    let lines: [StatLine]
}

/// A full snapshot of player diagnostics. Section-based so the future Stash transcoder can add its own
/// section without reworking the overlay.
struct PlaybackStats {
    let sections: [StatSection]
}
