import Foundation

/// Stash's **Tasks-page defaults** — the toggles ticked on the server's own *Library → Scan* and
/// *Generated Content → Generate* forms (config keys `defaults.scan` / `defaults.generate`).
///
/// ## Why this file exists (shipped bug, fixed v1.0.369)
/// **Stash applies no defaults of its own to `metadataScan` / `metadataGenerate`.** The scan flags live
/// in `config.ScanMetadataOptions`, embedded in `manager.ScanMetadataInput` as plain Go `bool`s, and
/// the resolver hands the input straight to `manager.Scan()` — so *every field the caller omits arrives
/// as `false`*. The ticks you see in the web UI are the saved config, applied **by the browser** when it
/// builds the mutation. Stashy used to send a literally empty `ScanMetadataInput()` under a comment
/// claiming "server defaults", so every scan it ever triggered — the jobs-panel chip and the Companion
/// plugin's post-fetch scan alike — was ingest-only: no cover, no preview, no scrubber sprite, no phash.
///
/// ## …and a later scan cannot repair it
/// `handlerRequiredFilter.Accept` (internal/manager/task_scan.go) returns true only when a file has
/// **zero** related objects. Once the scene row exists, an unchanged file skips the handler entirely, so
/// the scan-time generators never run again no matter which toggles are ticked. Backfilling a scene that
/// came in bare needs `metadataGenerate` (or a scan with `rescan`) — that is what the Generate action is
/// for, and why "just scan again" is not a fix.
///
/// So: read what the server has saved and send it explicitly, so a Stashy-triggered task behaves exactly
/// like the same task started from the Stash UI.
struct StashTaskDefaults: Sendable, Equatable {
    var scan: ScanOptions
    var generate: GenerateOptions

    /// Stash's stock ticks — used when the server has nothing saved, or when the query fails (an older
    /// schema rejects the newest fields).
    static let fallback = StashTaskDefaults(scan: .fallback, generate: .fallback)
}

/// The generation flags of Stash's `ScanMetadataInput`, named exactly as the schema does so `Codable`
/// synthesis maps them without `CodingKeys`.
///
/// Every field is `Bool?` on purpose. Synthesised `encode(to:)` uses `encodeIfPresent`, so a `nil`
/// encodes away entirely — which is what keeps the fallback path safe: a flag this server's schema
/// doesn't know would fail the whole mutation's validation, so `.fallback` sets only flags that predate
/// the newest schema additions (`scanGenerateImagePhashes` / `scanGenerateClipPreviews`). Fields read
/// back from a successful query are safe to send by construction — the query validated against the same
/// schema.
struct ScanOptions: Codable, Sendable, Equatable {
    var rescan: Bool? = nil
    var scanGenerateCovers: Bool? = nil
    var scanGeneratePreviews: Bool? = nil
    var scanGenerateImagePreviews: Bool? = nil
    var scanGenerateSprites: Bool? = nil
    var scanGeneratePhashes: Bool? = nil
    var scanGenerateImagePhashes: Bool? = nil
    var scanGenerateThumbnails: Bool? = nil
    var scanGenerateClipPreviews: Bool? = nil

    static let fallback = ScanOptions(
        scanGenerateCovers: true,
        scanGeneratePreviews: true,
        scanGenerateSprites: true,
        scanGeneratePhashes: true,
        scanGenerateThumbnails: true
    )

    /// True when at least one generator is switched on. An all-off payload means the server never saved
    /// that form, and a scan that generates nothing is precisely the bug this type exists to fix — so the
    /// loader substitutes the stock ticks instead of shipping a dud. `rescan` deliberately doesn't count.
    var generatesAnything: Bool {
        [scanGenerateCovers, scanGeneratePreviews, scanGenerateImagePreviews, scanGenerateSprites,
         scanGeneratePhashes, scanGenerateImagePhashes, scanGenerateThumbnails,
         scanGenerateClipPreviews].contains { $0 == true }
    }
}

/// The flags of Stash's `GenerateMetadataInput`, named as the schema does.
///
/// Two input fields are deliberately absent and controlled by the call site instead: `overwrite` (always
/// `false` — this is a backfill, never a rebuild) and the `sceneIDs` scope. `imagePhashes` is missing
/// from Stash's `GenerateMetadataOptions` *output* type, so there is no saved default to read and it
/// stays off.
struct GenerateOptions: Codable, Sendable, Equatable {
    var covers: Bool? = nil
    var sprites: Bool? = nil
    var previews: Bool? = nil
    var imagePreviews: Bool? = nil
    var markers: Bool? = nil
    var markerImagePreviews: Bool? = nil
    var markerScreenshots: Bool? = nil
    var transcodes: Bool? = nil
    var phashes: Bool? = nil
    var interactiveHeatmapsSpeeds: Bool? = nil
    var imageThumbnails: Bool? = nil
    var clipPreviews: Bool? = nil

    /// Stash's stock ticks. `transcodes` stays off on purpose — Stash's transcoder is hard-coded to
    /// H.264 and a library-wide transcode is hours of CPU nobody asked for by tapping "Generate".
    static let fallback = GenerateOptions(
        covers: true,
        sprites: true,
        previews: true,
        markers: true,
        markerImagePreviews: true,
        markerScreenshots: true,
        phashes: true,
        imageThumbnails: true
    )

    /// See `ScanOptions.generatesAnything` — an all-off Generate is a no-op button.
    var generatesAnything: Bool {
        [covers, sprites, previews, imagePreviews, markers, markerImagePreviews, markerScreenshots,
         transcodes, phashes, interactiveHeatmapsSpeeds, imageThumbnails,
         clipPreviews].contains { $0 == true }
    }
}

/// One-shot per-session cache of the server's saved ticks. It's a form's worth of booleans that only
/// changes when the owner edits the Stash UI, and it's read on a user tap, so a round trip per tap would
/// be pure latency.
@MainActor
enum StashTaskDefaultsCache {
    private static var cached: StashTaskDefaults?

    /// The server's saved ticks, fetched at most once per app run. A **failed** fetch is not cached: a
    /// transient blip must not pin the fallback for the rest of the session.
    static func load(client: StashClient?) async -> StashTaskDefaults {
        if let cached { return cached }
        guard let client, let fresh = try? await client.taskDefaults() else { return .fallback }
        cached = fresh
        return fresh
    }
}
