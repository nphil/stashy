import Foundation

/// Client-side gateway to the **Stashy Companion** Stash plugin (`stash-plugin/` in this repo).
///
/// Every capability the companion plugin exposes — iPhone-native HEVC/AV1 transcoding today; richer
/// stats, auto-tagging and cache management next — funnels through this ONE typed surface so the app
/// has a single, testable place to grow against. It speaks to the plugin the way any Stash client does:
/// `runPluginTask` to kick a task, `findJob` to watch live `Job.progress`, and the source scene's
/// `custom_fields` as the result side-channel (where the plugin records the finished download path).
///
/// Design note: this deliberately wraps a plain `StashClient` (the app's existing GraphQL transport)
/// rather than reinventing one, so retries / auth / error handling stay consistent with the rest of
/// the app. Keep new plugin features as methods here.
struct StashCompanion: Sendable {
    /// Plugin id = the manifest's filename stem (`stashy-companion.yml`). Used for `runPluginTask` and
    /// to build the `/plugin/<id>/assets/…` download URL.
    static let pluginID = "stashy-companion"
    /// custom_fields key the plugin writes the transcode result JSON under.
    static let transcodeField = "stashy_transcode"

    let client: StashClient

    // MARK: Task + option types

    /// Companion task names — must match `tasks[].name` in `stashy-companion.yml` exactly.
    enum Task: String, Sendable {
        case transcode = "Transcode for iPhone"
        case stats     = "Library Codec Report"
        case tag       = "Tag iPhone-Ready Scenes"
        case purge     = "Purge Transcode Cache"
    }

    /// Output codecs the plugin can produce. HEVC = GPU (hevc_nvenc) — the default; AV1 = CPU (SVT-AV1),
    /// smaller but much slower and gated behind the plugin's "Allow AV1" setting.
    enum Codec: String, Sendable, CaseIterable, Identifiable, Hashable {
        case hevc, av1
        var id: String { rawValue }
        var label: String { self == .hevc ? "HEVC" : "AV1" }
        var blurb: String {
            self == .hevc
                ? "H.265 · NVENC GPU · plays natively on iPhone"
                : "AV1 · CPU (slow) · smallest files · A17+ decode"
        }
    }

    // MARK: - Primitives

    /// Kick a companion task; returns the Stash Job id to poll.
    @discardableResult
    func run(_ task: Task, args: [String: String]) async throws -> String {
        let gql = """
        mutation RunPluginTask($id: ID!, $task: String!, $args: Map) {
          runPluginTask(plugin_id: $id, task_name: $task, args_map: $args)
        }
        """
        let resp: RunPluginTaskResponse = try await client.query(
            gql, variables: RunPluginTaskVars(id: Self.pluginID, task: task.rawValue, args: args))
        return resp.runPluginTask
    }

    /// Live status + progress (0…1, or nil when indeterminate) for a running job.
    func job(_ id: String) async throws -> CompanionJob {
        let gql = "query FindJob($id: ID!) { findJob(input: { id: $id }) { id status progress error } }"
        let resp: FindJobResponse = try await client.query(gql, variables: IDVar(id: id))
        guard let job = resp.findJob else {
            throw StashError.graphqlError("job \(id) not found")
        }
        return job
    }

    // MARK: - Transcode

    /// Ask the plugin to produce an iPhone-native copy of a scene. Returns the Job id. Poll `job(_:)`
    /// for progress, then read `transcodeResult(sceneID:)` once it reports FINISHED.
    @discardableResult
    func requestTranscode(sceneID: String, codec: Codec,
                          resolution: ServerQuality, quality: CompanionQuality) async throws -> String {
        try await run(.transcode, args: [
            "scene_id": sceneID,
            "codec": codec.rawValue,
            // Plugin RES_HEIGHTS accepts the "p1080"-style raw values directly.
            "resolution": resolution.rawValue,
            "quality": quality.arg,
        ])
    }

    /// The transcode result the plugin recorded on the scene's custom_fields, or nil if not ready.
    /// `status` is "running" | "ready" | "failed"; only "ready" carries a usable `path`.
    func transcodeResult(sceneID: String) async throws -> TranscodeResult? {
        let gql = "query SceneCF($id: ID!) { findScene(id: $id) { custom_fields } }"
        let resp: SceneCustomFieldsResponse = try await client.query(gql, variables: IDVar(id: sceneID))
        guard let raw = resp.findScene?.custom_fields[Self.transcodeField]?.stringValue,
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TranscodeResult.self, from: data)
    }
}

// MARK: - Option models

/// Quality preset passed to the plugin (maps to the encoder's CQ/CRF). Kept app-side so the download
/// UI can offer a friendly choice.
enum CompanionQuality: String, CaseIterable, Identifiable, Hashable, Sendable {
    case high, medium, low
    var id: String { rawValue }
    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Balanced"
        case .low: return "Small"
        }
    }
    var arg: String { rawValue }
}

// MARK: - Wire models

struct CompanionJob: Decodable, Sendable {
    let id: String
    let status: String        // READY | RUNNING | FINISHED | CANCELLED | FAILED | STOPPING
    let progress: Double?     // 0…1, or nil / negative when indeterminate
    let error: String?
}

/// Decoded from the JSON string the plugin stores in `custom_fields.stashy_transcode`. The plugin
/// ffprobes its own output, so `video_codec`/`width`/`height`/`bitrate` are the ACTUAL specs of the
/// produced file — use these to display/persist what the file really is, not what was requested.
struct TranscodeResult: Decodable, Sendable {
    let path: String?         // "/plugin/stashy-companion/assets/cache/…mp4" — nil until ready
    let size: Int64?
    let codec: String?        // actual video codec (== video_codec; kept for the badge)
    let resolution: Int?
    let container: String?
    let status: String?       // "running" | "ready" | "failed"
    let video_codec: String?
    let audio_codec: String?
    let width: Int?
    let height: Int?
    let bitrate: Int?
}

// MARK: - GraphQL request/response envelopes

private struct RunPluginTaskVars: Encodable, Sendable {
    let id: String
    let task: String
    let args: [String: String]
}
private struct RunPluginTaskResponse: Decodable, Sendable { let runPluginTask: String }

private struct IDVar: Encodable, Sendable { let id: String }
private struct FindJobResponse: Decodable, Sendable { let findJob: CompanionJob? }

private struct SceneCustomFieldsResponse: Decodable, Sendable { let findScene: SceneCustomFields? }
private struct SceneCustomFields: Decodable, Sendable { let custom_fields: [String: JSONValue] }

/// Minimal heterogeneous-JSON value, just enough to pull a string out of Stash's `Map!` scalar
/// (custom_fields can hold strings/numbers/bools written by any plugin). Reusable if future companion
/// features return richer maps.
enum JSONValue: Decodable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .null
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
}
