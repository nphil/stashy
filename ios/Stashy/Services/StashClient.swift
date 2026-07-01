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
        var sceneFilter: SceneFilter?
        if !q.tagIDs.isEmpty || q.performerID != nil {
            sceneFilter = SceneFilter(
                performers: q.performerID.map { MultiCriterion(value: [$0], modifier: "INCLUDES") },
                tags: q.tagIDs.isEmpty ? nil
                    : HierarchicalMultiCriterion(value: q.tagIDs, modifier: "INCLUDES_ALL", depth: 0)
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
}

// MARK: - Scene query model

enum SceneSort: String, CaseIterable, Sendable, Identifiable, Hashable {
    case date, createdAt, title, duration, size

    var id: String { rawValue }

    /// Stash sort column name.
    var apiKey: String {
        switch self {
        case .date: return "date"
        case .createdAt: return "created_at"
        case .title: return "title"
        case .duration: return "duration"
        case .size: return "filesize"
        }
    }

    var label: String {
        switch self {
        case .date: return "Date"
        case .createdAt: return "Date Added"
        case .title: return "Title"
        case .duration: return "Duration"
        case .size: return "File Size"
        }
    }

    var symbol: String {
        switch self {
        case .date: return "calendar"
        case .createdAt: return "clock"
        case .title: return "textformat"
        case .duration: return "timer"
        case .size: return "internaldrive"
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

    var tagIDs: [String] { tags.map(\.id) }
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
private struct SceneUpdateResponse: Decodable, Sendable { let sceneUpdate: RatingResult? }
private struct PerformerUpdateResponse: Decodable, Sendable { let performerUpdate: PerformerUpdateResult? }
private struct PerformerUpdateResult: Decodable, Sendable { let id: String; let rating100: Int?; let favorite: Bool? }
private struct TagUpdateResponse: Decodable, Sendable { let tagUpdate: FavoriteResult? }
private struct FindScenesVariables: Encodable, Sendable {
    let filter: FindFilter
    let scene_filter: SceneFilter?
}
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
