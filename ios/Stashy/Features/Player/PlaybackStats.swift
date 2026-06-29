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
}

// MARK: - Stats model

/// A single key/value row in the Stats overlay.
struct StatLine: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

/// A titled group of stat rows (e.g. "Playback", "Media", "Network", "Transcode").
struct StatSection: Identifiable {
    let id = UUID()
    let title: String
    let lines: [StatLine]
}

/// A full snapshot of player diagnostics. Section-based so the future Stash transcoder can add its own
/// section without reworking the overlay.
struct PlaybackStats {
    let sections: [StatSection]
}
