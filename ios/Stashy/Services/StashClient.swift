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

    // Shared scene selection set, reused across scene queries.
    private static let sceneFields = """
      id title date
      files { duration video_codec width height basename size }
      paths { screenshot preview sprite vtt }
      studio { id name }
      performers { id name image_path rating100 scene_count country birthdate gender urls }
      tags { id name }
      sceneStreams { url mime_type label }
    """

    private static let performerFields = "id name image_path rating100 scene_count country birthdate gender urls"

    /// Unified scene query: full-text search, sort + direction, optional tag and performer filters.
    func findScenes(_ q: SceneQuery, page: Int = 1, perPage: Int = 25) async throws -> FindScenesResult {
        let gql = """
        query FindScenes($filter: FindFilterType, $scene_filter: SceneFilterType) {
          findScenes(filter: $filter, scene_filter: $scene_filter) {
            count
            scenes { \(Self.sceneFields) }
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

    /// Tag lookup for the tag filter / search. Defaults to name-sorted; pass sort "scenes_count"
    /// (desc) for popularity.
    func findTags(query q: String, limit: Int = 20, sort: String = "name", direction: String = "ASC") async throws -> [Tag] {
        let gql = """
        query FindTags($filter: FindFilterType) {
          findTags(filter: $filter) { tags { id name } }
        }
        """
        let vars = FilterVariables(filter: FindFilter(q: q.isEmpty ? nil : q, page: 1, per_page: limit, sort: sort, direction: direction))
        let response: FindTagsResponse = try await query(gql, variables: vars)
        return response.findTags.tags
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
private struct FindScenesVariables: Encodable, Sendable {
    let filter: FindFilter
    let scene_filter: SceneFilter?
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
