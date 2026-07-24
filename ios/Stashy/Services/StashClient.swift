import Foundation

struct StashClient: Sendable {
    let serverURL: String
    let apiKey: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 100 * 1024 * 1024
        )
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    private var graphqlURL: URL {
        URL(string: "\(serverURL)/graphql")!
    }

    // MARK: - Generic query

    func query<T: Decodable & Sendable>(_ queryString: String) async throws -> T {
        try await query(queryString, variables: EmptyVariables())
    }

    func query<T: Decodable & Sendable, V: Encodable & Sendable>(
        _ queryString: String,
        variables: V
    ) async throws -> T {
        try await query(queryString, variables: variables, retry: 0)
    }

    /// Max transient retries for a locked Stash database before giving up.
    private static let maxLockRetries = 3

    private func query<T: Decodable & Sendable, V: Encodable & Sendable>(
        _ queryString: String,
        variables: V,
        retry: Int
    ) async throws -> T {
        var request = URLRequest(url: graphqlURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "ApiKey")

        let body = GraphQLRequest(query: queryString, variables: variables)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await Self.session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StashError.httpError(http.statusCode)
        }

        let gqlResponse = try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)

        if let errors = gqlResponse.errors, !errors.isEmpty {
            // Stash is SQLite-backed; a concurrent write can briefly lock the DB. That's transient, so
            // back off and retry rather than surfacing it as a failure (esp. mutations fired in bursts).
            if retry < Self.maxLockRetries,
               errors.contains(where: { $0.message.lowercased().contains("database is locked") }) {
                try await Task.sleep(for: .milliseconds(500 * (retry + 1)))
                return try await query(queryString, variables: variables, retry: retry + 1)
            }
            throw StashError.graphqlError(errors.map(\.message).joined(separator: "; "))
        }

        guard let result = gqlResponse.data else {
            throw StashError.noData
        }
        return result
    }

    // MARK: - Typed queries

    func stats() async throws -> StatsData {
        let q = "query { stats { scene_count performer_count studio_count tag_count } }"
        let response: StatsResponse = try await query(q)
        return response.stats
    }

    // Scene selection set for the *list* query. Deliberately slim on performers — a list can carry
    // dozens of scenes, and pulling every performer's full profile (rating, scene_count, urls, tags…)
    // for each one bloats the payload for data the card never shows. Just id+name here; the detail
    // view re-fetches the full set for the one scene being viewed via `findScene(id:)`. Everything the
    // card and the player need (files, paths, streams) stays in, so both open instantly.
    private static let sceneListFields = """
      id title date rating100
      files { duration video_codec width height basename size bit_rate frame_rate }
      paths { screenshot preview sprite vtt }
      studio { id name }
      performers { id name image_path }
      tags { id name }
      sceneStreams { url mime_type label }
    """

    // Full scene selection set for the single-scene detail fetch: complete performer profiles for the
    // performer cards and social links.
    private static let sceneDetailFields = """
      id title date rating100
      files { duration video_codec width height basename size bit_rate frame_rate }
      paths { screenshot preview sprite vtt }
      studio { id name }
      performers { \(performerFields) }
      tags { id name }
      sceneStreams { url mime_type label }
    """

    private static let performerFields = "id name image_path rating100 favorite scene_count country birthdate gender urls tags { id name }"

    /// Unified scene query: full-text search, sort + direction, optional tag and performer filters.
    func findScenes(_ q: SceneQuery, page: Int = 1, perPage: Int = 25) async throws -> FindScenesResult {
        let gql = """
        query FindScenes($filter: FindFilterType, $scene_filter: SceneFilterType) {
          findScenes(filter: $filter, scene_filter: $scene_filter) {
            count
            scenes { \(Self.sceneListFields) }
          }
        }
        """
        let tagIDs = q.tagIDs
        var sceneFilter: SceneFilter?
        if !tagIDs.isEmpty || q.performerID != nil {
            sceneFilter = SceneFilter(
                performers: q.performerID.map { MultiCriterion(value: [$0], modifier: "INCLUDES") },
                tags: tagIDs.isEmpty ? nil
                    : HierarchicalMultiCriterion(value: tagIDs, modifier: "INCLUDES_ALL", depth: 0)
            )
        }
        let vars = FindScenesVariables(
            filter: FindFilter(
                q: q.search.isEmpty ? nil : q.search,
                page: page,
                per_page: perPage,
                sort: q.sort.apiKey,
                direction: q.direction.rawValue
            ),
            scene_filter: sceneFilter
        )
        let response: FindScenesResponse = try await query(gql, variables: vars)
        return response.findScenes
    }

    /// Fetch a specific set of scenes by ID (used by the playability filter, which pages over the ID list
    /// from the plugin's served report). Results are re-ordered to match the requested `ids` order.
    func findScenesByIDs(_ ids: [String]) async throws -> [StashScene] {
        guard !ids.isEmpty else { return [] }
        let gql = """
        query FindScenesByIDs($ids: [ID!]) {
          findScenes(ids: $ids) {
            count
            scenes { \(Self.sceneListFields) }
          }
        }
        """
        let response: FindScenesResponse = try await query(gql, variables: SceneIDsVariables(ids: ids))
        let byID = Dictionary(response.findScenes.scenes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// Full detail for a single scene (complete performer profiles + social links). The list query
    /// returns performers slimmed to id+name; the detail view calls this to fill in the rest for the
    /// one scene on screen.
    func findScene(id: String) async throws -> StashScene? {
        let gql = """
        query FindScene($id: ID!) {
          findScene(id: $id) { \(Self.sceneDetailFields) }
        }
        """
        let response: FindSceneResponse = try await query(gql, variables: FindSceneVariables(id: id))
        return response.findScene
    }

    func findPerformers(page: Int = 1, perPage: Int = 25, query q: String = "") async throws -> FindPerformersResult {
        let gql = """
        query FindPerformers($filter: FindFilterType) {
          findPerformers(filter: $filter) {
            count
            performers { \(Self.performerFields) }
          }
        }
        """
        let vars = FilterVariables(filter: FindFilter(q: q.isEmpty ? nil : q, page: page, per_page: perPage, sort: "name", direction: "ASC"))
        let response: FindPerformersResponse = try await query(gql, variables: vars)
        return response.findPerformers
    }

    /// Unified performer query: name search, sort + direction, optional ethnicity and tag filters.
    func findPerformers(_ q: PerformerQuery, page: Int = 1, perPage: Int = 30) async throws -> FindPerformersResult {
        let gql = """
        query FindPerformers($filter: FindFilterType, $performer_filter: PerformerFilterType) {
          findPerformers(filter: $filter, performer_filter: $performer_filter) {
            count
            performers { \(Self.performerFields) }
          }
        }
        """
        var performerFilter: PerformerFilter?
        let ethnicity = q.ethnicity?.trimmingCharacters(in: .whitespaces)
        if let ethnicity, !ethnicity.isEmpty {
            performerFilter = PerformerFilter(ethnicity: StringCriterion(value: ethnicity, modifier: "EQUALS"))
        }
        if !q.tagIDs.isEmpty {
            performerFilter = (performerFilter ?? PerformerFilter())
            performerFilter?.tags = HierarchicalMultiCriterion(value: q.tagIDs, modifier: "INCLUDES_ALL", depth: 0)
        }
        if q.favoritesOnly {
            performerFilter = (performerFilter ?? PerformerFilter())
            performerFilter?.filter_favorites = true
        }
        let vars = FindPerformersFilterVariables(
            filter: FindFilter(
                q: q.search.isEmpty ? nil : q.search,
                page: page,
                per_page: perPage,
                sort: q.sort.apiKey,
                direction: q.direction.rawValue
            ),
            performer_filter: performerFilter
        )
        let response: FindPerformersResponse = try await query(gql, variables: vars)
        return response.findPerformers
    }

    /// Tag lookup for the tag filter / search. Defaults to name-sorted; pass sort "scenes_count"
    /// (desc) for popularity.
    func findTags(query q: String, limit: Int = 20, sort: String = "name", direction: String = "ASC") async throws -> [Tag] {
        let gql = """
        query FindTags($filter: FindFilterType) {
          findTags(filter: $filter) { tags { id name favorite } }
        }
        """
        let vars = FilterVariables(filter: FindFilter(q: q.isEmpty ? nil : q, page: 1, per_page: limit, sort: sort, direction: direction))
        let response: FindTagsResponse = try await query(gql, variables: vars)
        return response.findTags.tags
    }

    // MARK: - Mutations (ratings + favorites)
    //
    // All are single-field updates used behind optimistic UI: the control flips instantly, these persist
    // in the background, and the caller reverts only if the mutation throws. Rating clears (nil) send an
    // explicit `null` so Stash unsets the value rather than leaving it unchanged.

    /// Set (or clear, when nil) a scene's 0–100 rating. Returns the server's stored value.
    @discardableResult
    func setSceneRating(id: String, rating100: Int?) async throws -> Int? {
        let gql = """
        mutation SceneUpdate($input: SceneUpdateInput!) {
          sceneUpdate(input: $input) { id rating100 }
        }
        """
        let response: SceneUpdateResponse = try await query(
            gql, variables: RatingInputVariables(input: RatingInput(id: id, rating100: rating100)))
        return response.sceneUpdate?.rating100
    }

    /// Set (or clear, when nil) a performer's 0–100 rating. Returns the server's stored value.
    @discardableResult
    func setPerformerRating(id: String, rating100: Int?) async throws -> Int? {
        let gql = """
        mutation PerformerUpdate($input: PerformerUpdateInput!) {
          performerUpdate(input: $input) { id rating100 }
        }
        """
        let response: PerformerUpdateResponse = try await query(
            gql, variables: RatingInputVariables(input: RatingInput(id: id, rating100: rating100)))
        return response.performerUpdate?.rating100
    }

    /// Toggle a performer's favorite flag. Returns the server's stored value.
    @discardableResult
    func setPerformerFavorite(id: String, favorite: Bool) async throws -> Bool? {
        let gql = """
        mutation PerformerUpdate($input: PerformerUpdateInput!) {
          performerUpdate(input: $input) { id favorite }
        }
        """
        let response: PerformerUpdateResponse = try await query(
            gql, variables: FavoriteInputVariables(input: FavoriteInput(id: id, favorite: favorite)))
        return response.performerUpdate?.favorite
    }

    /// Toggle a tag's favorite flag. Returns the server's stored value.
    @discardableResult
    func setTagFavorite(id: String, favorite: Bool) async throws -> Bool? {
        let gql = """
        mutation TagUpdate($input: TagUpdateInput!) {
          tagUpdate(input: $input) { id favorite }
        }
        """
        let response: TagUpdateResponse = try await query(
            gql, variables: FavoriteInputVariables(input: FavoriteInput(id: id, favorite: favorite)))
        return response.tagUpdate?.favorite
    }

    /// Remove a scene from Stash. `deleteFile` also deletes the source media file from disk (destructive
    /// and irreversible) — defaults to false, so by default only the library entry + generated content
    /// (previews/sprites) are removed and the original file is left in place.
    @discardableResult
    func deleteScene(id: String, deleteFile: Bool = false) async throws -> Bool {
        let gql = "mutation SceneDestroy($input: SceneDestroyInput!) { sceneDestroy(input: $input) }"
        let response: SceneDestroyResponse = try await query(
            gql, variables: SceneDestroyVariables(input: SceneDestroyInput(id: id, delete_file: deleteFile, delete_generated: true)))
        return response.sceneDestroy ?? false
    }

    /// Remove several scenes at once (used when cascading a performer delete to their scenes).
    @discardableResult
    func deleteScenes(ids: [String], deleteFile: Bool) async throws -> Bool {
        guard !ids.isEmpty else { return true }
        let gql = "mutation ScenesDestroy($input: ScenesDestroyInput!) { scenesDestroy(input: $input) }"
        let response: ScenesDestroyResponse = try await query(
            gql, variables: ScenesDestroyVariables(input: ScenesDestroyInput(ids: ids, delete_file: deleteFile, delete_generated: true)))
        return response.scenesDestroy ?? false
    }

    /// Remove a performer from Stash (does not touch scene files).
    @discardableResult
    func deletePerformer(id: String) async throws -> Bool {
        let gql = "mutation PerformerDestroy($input: PerformerDestroyInput!) { performerDestroy(input: $input) }"
        let response: PerformerDestroyResponse = try await query(
            gql, variables: PerformerDestroyVariables(input: PerformerDestroyInput(id: id)))
        return response.performerDestroy ?? false
    }

    /// Every scene id featuring a performer (paginated, minimal `{ id }` selection) — for cascade delete.
    func sceneIDs(performerID: String) async throws -> [String] {
        let gql = """
        query FindSceneIDs($filter: FindFilterType, $scene_filter: SceneFilterType) {
          findScenes(filter: $filter, scene_filter: $scene_filter) { count scenes { id } }
        }
        """
        let filter = SceneFilter(performers: MultiCriterion(value: [performerID], modifier: "INCLUDES"))
        var ids: [String] = []
        var page = 1
        let perPage = 200
        while true {
            let vars = FindScenesVariables(
                filter: FindFilter(page: page, per_page: perPage), scene_filter: filter)
            let response: FindSceneIDsResponse = try await query(gql, variables: vars)
            ids.append(contentsOf: response.findScenes.scenes.map(\.id))
            if ids.count >= response.findScenes.count || response.findScenes.scenes.isEmpty { break }
            page += 1
        }
        return ids
    }

    // MARK: - Job queue / library scan

    /// The whole Stash job queue (running + queued). Used by the jobs panel — only called while it's open.
    /// Stash declares `jobQueue: [Job!]` (nullable list) and its Go resolver returns a nil slice when the
    /// queue is EMPTY, so the wire value for "no jobs" is `null`, not `[]`. Decode it optionally — a
    /// non-optional array made every idle-queue poll a decode failure, which froze the panel's last
    /// snapshot mid-scan and eventually killed the monitor's poll loop (the stuck-progress-bar bug).
    func jobQueue() async throws -> [JobInfo] {
        struct Response: Decodable, Sendable { let jobQueue: [JobInfo]? }
        let resp: Response = try await query(
            "query JobQueue { jobQueue { id status description subTasks progress } }")
        return resp.jobQueue ?? []
    }

    /// Kick Stash's native library scan with server defaults (all configured paths). Returns the Job id.
    @discardableResult
    func metadataScan() async throws -> String {
        struct Response: Decodable, Sendable { let metadataScan: String }
        let gql = "mutation MetadataScan($input: ScanMetadataInput!) { metadataScan(input: $input) }"
        let resp: Response = try await query(gql, variables: ScanMetadataVariables(input: ScanMetadataInput()))
        return resp.metadataScan
    }

    /// Ask Stash to stop a running/queued job (the jobs panel's cancel button). `stopJob(job_id:)` returns
    /// true when the stop was accepted; the job then transitions to STOPPING → CANCELLED in the queue.
    @discardableResult
    func stopJob(id: String) async throws -> Bool {
        struct Response: Decodable, Sendable { let stopJob: Bool }
        let gql = "mutation StopJob($job_id: ID!) { stopJob(job_id: $job_id) }"
        let resp: Response = try await query(gql, variables: StopJobVariables(job_id: id))
        return resp.stopJob
    }
}

/// One entry in Stash's job queue. `progress` is 0…1 (nil = indeterminate); `status` is one of
/// READY / RUNNING / STOPPING / FINISHED / CANCELLED / FAILED.
struct JobInfo: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let status: String
    let description: String
    let subTasks: [String]?
    let progress: Double?
}

private struct ScanMetadataInput: Encodable, Sendable {}   // empty = scan all library paths, server defaults
private struct ScanMetadataVariables: Encodable, Sendable { let input: ScanMetadataInput }
private struct StopJobVariables: Encodable, Sendable { let job_id: String }

// MARK: - Scene query model

enum SceneSort: String, CaseIterable, Sendable, Identifiable, Hashable {
    case date, createdAt, title, duration, size, resolution, framerate, quality

    var id: String { rawValue }

    /// Stash sort column name. `resolution` / `framerate` are native Stash sort keys; `quality` has no
    /// native equivalent (it's the plugin's bits-per-pixel score) — the app reorders by the report, and this
    /// `bitrate` key is only the fallback when the report isn't loaded.
    var apiKey: String {
        switch self {
        case .date: return "date"
        case .createdAt: return "created_at"
        case .title: return "title"
        case .duration: return "duration"
        case .size: return "filesize"
        case .resolution: return "resolution"
        case .framerate: return "framerate"
        case .quality: return "bitrate"
        }
    }

    /// True when the sort is computed from the Companion plugin's report (`PlayabilityStore`) rather than a
    /// native Stash column — the scene list is then reordered client-side over the report's scene IDs.
    var isReportSort: Bool { self == .resolution || self == .framerate || self == .quality }

    var label: String {
        switch self {
        case .date: return "Date"
        case .createdAt: return "Date Added"
        case .title: return "Title"
        case .duration: return "Duration"
        case .size: return "File Size"
        case .resolution: return "Resolution"
        case .framerate: return "Frame Rate"
        case .quality: return "Quality"
        }
    }

    var symbol: String {
        switch self {
        case .date: return "calendar"
        case .createdAt: return "clock"
        case .title: return "textformat"
        case .duration: return "timer"
        case .size: return "internaldrive"
        case .resolution: return "rectangle.on.rectangle"
        case .framerate: return "speedometer"
        case .quality: return "sparkles"
        }
    }
}

enum SortDirection: String, Sendable, Hashable {
    case asc = "ASC"
    case desc = "DESC"
    var toggled: SortDirection { self == .asc ? .desc : .asc }
}

struct SceneQuery: Sendable, Equatable {
    var search: String = ""
    var sort: SceneSort = .date
    var direction: SortDirection = .desc
    var tags: [Tag] = []
    var performerID: String? = nil
    /// Client-side filter: show only scenes that have a completed on-device download (not a Stash concept).
    var downloadedOnly: Bool = false
    /// Playability filter — resolved from the Companion plugin's served report (via `PlayabilityStore`),
    /// NOT from tags (the plugin writes no tags). When not `.any`, the scene list is paged over that
    /// bucket's scene IDs instead of the normal library query. `.any` = normal library.
    var playability: Playability = .any
    /// Resolution / frame-rate / quality filters — all resolved from the Companion plugin's served report
    /// (via `PlayabilityStore`), like `playability`. When any report filter is active the list is paged over
    /// the matching scene IDs instead of the normal library query.
    var resolution: ResolutionFilter = .any
    var fps: FPSFilter = .any
    var quality: QualityFilter = .any

    var tagIDs: [String] { tags.map(\.id) }

    /// True when a plugin-report-derived filter (playability / resolution / fps / quality) is active — the
    /// scene list is then paged over `PlayabilityStore.matchingIDs` rather than the normal library query.
    var usesReport: Bool {
        playability != .any || resolution != .any || fps != .any || quality != .any
    }
}

/// Minimum-resolution buckets (scene height from the plugin report).
enum ResolutionFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case any, uhd, fhd, hd
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: return "Any"; case .uhd: return "4K+"; case .fhd: return "1080p+"; case .hd: return "720p+"
        }
    }
    /// Minimum height (px) a scene must meet, or nil for no filter.
    var minHeight: Int? {
        switch self { case .any: return nil; case .uhd: return 2160; case .fhd: return 1080; case .hd: return 720 }
    }
}

/// Frame-rate buckets. `high` ≈ 50/60 fps; `standard` is everything below.
enum FPSFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case any, high, standard
    var id: String { rawValue }
    var label: String {
        switch self { case .any: return "Any"; case .high: return "60fps"; case .standard: return "30fps" }
    }
    /// Returns whether a scene's fps passes this bucket (nil = no filter).
    func passes(_ fps: Double?) -> Bool {
        switch self {
        case .any: return true
        case .high: return (fps ?? 0) >= 48
        case .standard: return (fps ?? 0) > 0 && (fps ?? 0) < 48
        }
    }
}

/// Quality buckets from the plugin's codec-normalized bits-per-pixel score. Filter is "at least this tier".
enum QualityFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case any, low, standard, high, ultra
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: return "Any"; case .low: return "Low+"; case .standard: return "Standard+"
        case .high: return "High+"; case .ultra: return "Ultra"
        }
    }
    /// Rank ordering low < standard < high < ultra; nil = no filter.
    var minRank: Int? {
        switch self {
        case .any: return nil; case .low: return 1; case .standard: return 2; case .high: return 3; case .ultra: return 4
        }
    }
    static func rank(_ quality: String) -> Int {
        switch quality { case "low": return 1; case "standard": return 2; case "high": return 3; case "ultra": return 4; default: return 0 }
    }
}

/// Which playability bucket to show — resolved from the plugin's served `playability.json`, not from tags.
enum Playability: String, Sendable, Equatable, CaseIterable, Identifiable {
    case any, directPlay, needsRemux, needsTranscode
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: return "Any"
        case .directPlay: return "Direct-play"
        case .needsRemux: return "Needs remux"
        case .needsTranscode: return "Needs transcode"
        }
    }
    /// The plugin report's `tier` string this bucket maps to (nil = no filter / show everything).
    var tier: String? {
        switch self {
        case .any: return nil
        case .directPlay: return "direct"
        case .needsRemux: return "remux"
        case .needsTranscode: return "transcode"
        }
    }
}

enum PerformerSort: String, CaseIterable, Sendable, Identifiable, Hashable {
    case name, sceneCount, rating, createdAt

    var id: String { rawValue }

    var apiKey: String {
        switch self {
        case .name: return "name"
        case .sceneCount: return "scenes_count"
        case .rating: return "rating"
        case .createdAt: return "created_at"
        }
    }

    var label: String {
        switch self {
        case .name: return "Name"
        case .sceneCount: return "Scene Count"
        case .rating: return "Rating"
        case .createdAt: return "Date Added"
        }
    }

    var symbol: String {
        switch self {
        case .name: return "textformat"
        case .sceneCount: return "film.stack"
        case .rating: return "star"
        case .createdAt: return "clock"
        }
    }
}

struct PerformerQuery: Sendable, Equatable {
    var search: String = ""
    var sort: PerformerSort = .name
    var direction: SortDirection = .asc
    var ethnicity: String? = nil
    var tags: [Tag] = []
    var favoritesOnly: Bool = false

    var tagIDs: [String] { tags.map(\.id) }
}

// MARK: - Request / response types

private struct GraphQLRequest<V: Encodable>: Encodable {
    let query: String
    let variables: V
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorItem]?

    struct GraphQLErrorItem: Decodable {
        let message: String
    }
}

private struct EmptyVariables: Encodable, Sendable {}

struct FindFilter: Encodable, Sendable {
    let q: String?
    let page: Int
    let per_page: Int
    let sort: String?
    let direction: String?

    init(q: String? = nil, page: Int = 1, per_page: Int = 25, sort: String? = nil, direction: String? = nil) {
        self.q = q
        self.page = page
        self.per_page = per_page
        self.sort = sort
        self.direction = direction
    }
}

private struct FilterVariables: Encodable, Sendable { let filter: FindFilter }
private struct FindSceneVariables: Encodable, Sendable { let id: String }

// MARK: Mutation inputs

/// `{id, rating100}` update input. `rating100` is always encoded — as `null` when nil — so a clear
/// unsets the rating instead of leaving it unchanged (Stash omits unspecified fields on update).
private struct RatingInput: Encodable, Sendable {
    let id: String
    let rating100: Int?
    enum CodingKeys: String, CodingKey { case id, rating100 }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if let rating100 { try c.encode(rating100, forKey: .rating100) }
        else { try c.encodeNil(forKey: .rating100) }
    }
}
private struct RatingInputVariables: Encodable, Sendable { let input: RatingInput }

private struct FavoriteInput: Encodable, Sendable {
    let id: String
    let favorite: Bool
}
private struct FavoriteInputVariables: Encodable, Sendable { let input: FavoriteInput }

// MARK: Mutation responses

private struct RatingResult: Decodable, Sendable { let id: String; let rating100: Int? }
private struct FavoriteResult: Decodable, Sendable { let id: String; let favorite: Bool? }
private struct SceneDestroyInput: Encodable, Sendable { let id: String; let delete_file: Bool; let delete_generated: Bool }
private struct SceneDestroyVariables: Encodable, Sendable { let input: SceneDestroyInput }
private struct SceneDestroyResponse: Decodable, Sendable { let sceneDestroy: Bool? }
private struct ScenesDestroyInput: Encodable, Sendable { let ids: [String]; let delete_file: Bool; let delete_generated: Bool }
private struct ScenesDestroyVariables: Encodable, Sendable { let input: ScenesDestroyInput }
private struct ScenesDestroyResponse: Decodable, Sendable { let scenesDestroy: Bool? }
private struct PerformerDestroyInput: Encodable, Sendable { let id: String }
private struct PerformerDestroyVariables: Encodable, Sendable { let input: PerformerDestroyInput }
private struct PerformerDestroyResponse: Decodable, Sendable { let performerDestroy: Bool? }

private struct FindSceneIDsResponse: Decodable, Sendable {
    let findScenes: SceneIDsResult
    struct SceneIDsResult: Decodable, Sendable { let count: Int; let scenes: [IDOnly] }
    struct IDOnly: Decodable, Sendable { let id: String }
}

private struct SceneUpdateResponse: Decodable, Sendable { let sceneUpdate: RatingResult? }
private struct PerformerUpdateResponse: Decodable, Sendable { let performerUpdate: PerformerUpdateResult? }
private struct PerformerUpdateResult: Decodable, Sendable { let id: String; let rating100: Int?; let favorite: Bool? }
private struct TagUpdateResponse: Decodable, Sendable { let tagUpdate: FavoriteResult? }
private struct FindScenesVariables: Encodable, Sendable {
    let filter: FindFilter
    let scene_filter: SceneFilter?
}
private struct SceneIDsVariables: Encodable, Sendable { let ids: [String] }
private struct FindPerformersFilterVariables: Encodable, Sendable {
    let filter: FindFilter
    let performer_filter: PerformerFilter?
}

struct PerformerFilter: Encodable, Sendable {
    var ethnicity: StringCriterion? = nil
    var tags: HierarchicalMultiCriterion? = nil
    var filter_favorites: Bool? = nil
}

struct StringCriterion: Encodable, Sendable {
    let value: String
    let modifier: String
}

struct SceneFilter: Encodable, Sendable {
    var performers: MultiCriterion? = nil
    var tags: HierarchicalMultiCriterion? = nil
}

struct MultiCriterion: Encodable, Sendable {
    let value: [String]
    let modifier: String
}

struct HierarchicalMultiCriterion: Encodable, Sendable {
    let value: [String]
    let modifier: String
    let depth: Int
}

struct StatsResponse: Decodable, Sendable { let stats: StatsData }
struct StatsData: Decodable, Sendable {
    let scene_count: Int
    let performer_count: Int
    let studio_count: Int?
    let tag_count: Int?
}

struct FindSceneResponse: Decodable, Sendable { let findScene: StashScene? }

struct FindScenesResponse: Decodable, Sendable { let findScenes: FindScenesResult }
struct FindScenesResult: Decodable, Sendable {
    let count: Int
    let scenes: [StashScene]
}

struct FindPerformersResponse: Decodable, Sendable { let findPerformers: FindPerformersResult }
struct FindPerformersResult: Decodable, Sendable {
    let count: Int
    let performers: [Performer]
}

struct FindTagsResponse: Decodable, Sendable { let findTags: FindTagsResult }
struct FindTagsResult: Decodable, Sendable { let tags: [Tag] }

enum StashError: LocalizedError {
    case httpError(Int)
    case graphqlError(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Server returned HTTP \(code)"
        case .graphqlError(let msg): return msg
        case .noData: return "No data returned from server"
        }
    }
}
