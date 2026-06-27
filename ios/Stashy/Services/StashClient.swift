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

    func findScenes(page: Int = 1, perPage: Int = 25, query q: String = "") async throws -> FindScenesResult {
        let gql = """
        query FindScenes($filter: FindFilterType) {
          findScenes(filter: $filter) {
            count
            scenes {
              id title date
              files { duration }
              paths { screenshot }
              studio { id name }
              performers { id name image_path }
              tags { id name }
              sceneStreams { url mime_type label }
            }
          }
        }
        """
        let vars = FindScenesVariables(filter: FindFilter(q: q.isEmpty ? nil : q, page: page, per_page: perPage))
        let response: FindScenesResponse = try await query(gql, variables: vars)
        return response.findScenes
    }

    func findPerformers(page: Int = 1, perPage: Int = 25, query q: String = "") async throws -> FindPerformersResult {
        let gql = """
        query FindPerformers($filter: FindFilterType) {
          findPerformers(filter: $filter) {
            count
            performers { id name image_path }
          }
        }
        """
        let vars = FindPerformersVariables(filter: FindFilter(q: q.isEmpty ? nil : q, page: page, per_page: perPage))
        let response: FindPerformersResponse = try await query(gql, variables: vars)
        return response.findPerformers
    }
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

    init(q: String? = nil, page: Int = 1, per_page: Int = 25, sort: String? = nil) {
        self.q = q
        self.page = page
        self.per_page = per_page
        self.sort = sort
    }
}

private struct FindScenesVariables: Encodable, Sendable { let filter: FindFilter }
private struct FindPerformersVariables: Encodable, Sendable { let filter: FindFilter }

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
