import Foundation

/// Client-side gateway to Stash's metadata scraping + editing API: scene scrape/edit, performer
/// scrape/edit/create, and the supporting tag/studio creation. Wraps the app's `StashClient` (the
/// existing GraphQL transport) the same way `StashCompanion` does, so retries / auth / error handling
/// stay consistent.
///
/// Every GraphQL shape here was verified verbatim against stashapp/stash master
/// (graphql/schema/types/scraper.graphql, scraped-performer.graphql, scene.graphql, performer.graphql,
/// stash-box.graphql) and the selection sets mirror the fragments Stash's own web UI sends
/// (ui/v2.5/graphql/data/scrapers.graphql), trimmed to the fields this app renders/applies.
/// Key contracts:
///  • `ScraperSourceInput` is a tagged union by convention: set EXACTLY ONE of `scraper_id` or
///    `stash_box_endpoint`.
///  • All `Scraped*` fields are nullable except `ScrapedStudio.name` / `ScrapedTag.name`.
///  • `stored_id` = the LOCAL Stash object a scraped entity matched (nil = not in the library).
///  • Scraped images arrive as base64 data URLs (server-side fetched); `cover_image` / `image`
///    mutation fields accept "a URL or a base64 encoded data URL" — pass through unchanged.
///  • Update inputs are partial: omitted (nil-encoded-away) fields stay unchanged; list fields
///    (`performer_ids`, `tag_ids`, `urls`, `stash_ids`) REPLACE the whole list.
struct StashScraper: Sendable {
    let client: StashClient

    // MARK: - Sources

    /// One pickable scrape source. Mirrors Stash's own dropdown: stash-box accounts (StashDB / FansDB /
    /// ThePornDB…) listed first, then installed scrapers with the needed capability.
    struct Source: Identifiable, Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case scraper(id: String)
            case stashBox(endpoint: String)
        }
        let kind: Kind
        let name: String
        var id: String {
            switch kind {
            case .scraper(let id): return "scraper:\(id)"
            case .stashBox(let endpoint): return "box:\(endpoint)"
            }
        }
        var isStashBox: Bool { if case .stashBox = kind { return true }; return false }
    }

    private struct SourceInput: Encodable, Sendable {
        var scraper_id: String?
        var stash_box_endpoint: String?
        init(_ source: Source) {
            switch source.kind {
            case .scraper(let id): scraper_id = id
            case .stashBox(let endpoint): stash_box_endpoint = endpoint
            }
        }
    }

    private struct ScrapersAndBoxes: Decodable, Sendable {
        struct Spec: Decodable, Sendable { let supported_scrapes: [String]? }
        struct Scraper: Decodable, Sendable {
            let id: String
            let name: String
            let scene: Spec?
            let performer: Spec?
        }
        struct Box: Decodable, Sendable { let endpoint: String; let name: String }
        struct General: Decodable, Sendable { let stashBoxes: [Box]? }
        struct Config: Decodable, Sendable { let general: General }
        let listScrapers: [Scraper]?
        let configuration: Config
    }

    /// Sources able to scrape a stored scene directly (stash-boxes query by fingerprint; classic
    /// scrapers need FRAGMENT support). One round trip for both lists.
    func sceneSources() async throws -> [Source] {
        let gql = """
        query SceneScrapeSources {
          listScrapers(types: [SCENE]) { id name scene { supported_scrapes } }
          configuration { general { stashBoxes { endpoint name } } }
        }
        """
        let resp: ScrapersAndBoxes = try await client.query(gql)
        return merge(resp, capability: { $0.scene?.supported_scrapes?.contains("FRAGMENT") == true })
    }

    /// Sources able to search performers by name (stash-boxes always can; classic scrapers need NAME).
    func performerSources() async throws -> [Source] {
        let gql = """
        query PerformerScrapeSources {
          listScrapers(types: [PERFORMER]) { id name performer { supported_scrapes } }
          configuration { general { stashBoxes { endpoint name } } }
        }
        """
        let resp: ScrapersAndBoxes = try await client.query(gql)
        return merge(resp, capability: { $0.performer?.supported_scrapes?.contains("NAME") == true })
    }

    private func merge(_ resp: ScrapersAndBoxes,
                       capability: (ScrapersAndBoxes.Scraper) -> Bool) -> [Source] {
        // Stash-box accounts first (Stash's own ordering), then capable scrapers by name.
        var out: [Source] = (resp.configuration.general.stashBoxes ?? []).enumerated().map { i, box in
            Source(kind: .stashBox(endpoint: box.endpoint),
                   name: box.name.isEmpty ? "Stash-Box #\(i + 1)" : box.name)
        }
        out += (resp.listScrapers ?? [])
            .filter(capability)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { Source(kind: .scraper(id: $0.id), name: $0.name) }
        return out
    }

    // MARK: - Scraped wire models

    struct ScrapedTagData: Decodable, Sendable, Hashable {
        let stored_id: String?
        let name: String
    }

    struct ScrapedStudioData: Decodable, Sendable, Hashable {
        let stored_id: String?
        let name: String
        let remote_site_id: String?
    }

    struct ScrapedPerformerData: Decodable, Sendable, Hashable, Identifiable {
        let stored_id: String?
        let name: String?
        let disambiguation: String?
        let gender: String?
        let urls: [String]?
        let birthdate: String?
        let death_date: String?
        let ethnicity: String?
        let country: String?
        let eye_color: String?
        let hair_color: String?
        let height: String?
        let weight: String?
        let measurements: String?
        let tattoos: String?
        let piercings: String?
        let aliases: String?          // comma-delimited per schema comment
        let details: String?
        let images: [String]?
        let remote_site_id: String?
        // List identity for result rows; remote id is unique per site, name+birthdate breaks the rare tie.
        var id: String { remote_site_id ?? "\(name ?? "?")|\(disambiguation ?? "")|\(birthdate ?? "")" }
    }

    struct ScrapedSceneData: Decodable, Sendable, Hashable {
        let title: String?
        let details: String?
        let date: String?
        let urls: [String]?
        let image: String?            // base64 data URL (server already fetched it)
        let studio: ScrapedStudioData?
        let tags: [ScrapedTagData]?
        let performers: [ScrapedPerformerData]?
        let remote_site_id: String?
    }

    /// The selection set for scraped performers — shared by the scene scrape (nested) and the performer
    /// search/detail queries. Mirrors the web UI's ScrapedPerformerData fragment minus fields the app
    /// doesn't render (career, fake_tits, circumcised, penis_length, tags).
    private static let scrapedPerformerFields = """
      stored_id name disambiguation gender urls birthdate death_date ethnicity country eye_color \
      hair_color height weight measurements tattoos piercings aliases details images remote_site_id
    """

    // MARK: - Scrape queries

    /// Scrape a stored scene directly (`input: {scene_id}` — stash-box fingerprint match or a FRAGMENT
    /// scraper). Returns every candidate; Stash's UI takes the first for classic scrapers, stash-boxes
    /// can return several fingerprint matches.
    func scrapeScene(source: Source, sceneID: String) async throws -> [ScrapedSceneData] {
        struct Input: Encodable, Sendable { let scene_id: String }
        struct Vars: Encodable, Sendable { let source: SourceInput; let input: Input }
        struct Resp: Decodable, Sendable { let scrapeSingleScene: [ScrapedSceneData]? }
        let gql = """
        query ScrapeSingleScene($source: ScraperSourceInput!, $input: ScrapeSingleSceneInput!) {
          scrapeSingleScene(source: $source, input: $input) {
            title details date urls image remote_site_id
            studio { stored_id name remote_site_id }
            tags { stored_id name }
            performers { \(Self.scrapedPerformerFields) }
          }
        }
        """
        let resp: Resp = try await client.query(
            gql, variables: Vars(source: SourceInput(source), input: Input(scene_id: sceneID)))
        return resp.scrapeSingleScene ?? []
    }

    /// Search performers by name (`input: {query}`). Stash-box results come back complete; classic
    /// scrapers return name-level skeletons — fill them in with `performerDetail`.
    func searchPerformers(source: Source, name: String) async throws -> [ScrapedPerformerData] {
        struct Input: Encodable, Sendable { let query: String }
        struct Vars: Encodable, Sendable { let source: SourceInput; let input: Input }
        struct Resp: Decodable, Sendable { let scrapeSinglePerformer: [ScrapedPerformerData]? }
        let gql = """
        query ScrapeSinglePerformer($source: ScraperSourceInput!, $input: ScrapeSinglePerformerInput!) {
          scrapeSinglePerformer(source: $source, input: $input) {
            \(Self.scrapedPerformerFields)
          }
        }
        """
        let resp: Resp = try await client.query(
            gql, variables: Vars(source: SourceInput(source), input: Input(query: name)))
        return resp.scrapeSinglePerformer ?? []
    }

    /// Full detail for a chosen search result. Stash-box results are already complete (returned as-is);
    /// a classic scraper is re-queried with the candidate as a fragment (`input: {performer_input}`),
    /// exactly like Stash's web UI (which strips images/tags from the fragment before sending).
    func performerDetail(source: Source, candidate: ScrapedPerformerData) async throws -> ScrapedPerformerData {
        guard !source.isStashBox else { return candidate }
        struct Fragment: Encodable, Sendable {
            let name: String?
            let disambiguation: String?
            let urls: [String]?
            let remote_site_id: String?
        }
        struct Input: Encodable, Sendable { let performer_input: Fragment }
        struct Vars: Encodable, Sendable { let source: SourceInput; let input: Input }
        struct Resp: Decodable, Sendable { let scrapeSinglePerformer: [ScrapedPerformerData]? }
        let gql = """
        query ScrapePerformerFragment($source: ScraperSourceInput!, $input: ScrapeSinglePerformerInput!) {
          scrapeSinglePerformer(source: $source, input: $input) {
            \(Self.scrapedPerformerFields)
          }
        }
        """
        let fragment = Fragment(name: candidate.name, disambiguation: candidate.disambiguation,
                                urls: candidate.urls, remote_site_id: candidate.remote_site_id)
        let resp: Resp = try await client.query(
            gql, variables: Vars(source: SourceInput(source), input: Input(performer_input: fragment)))
        return resp.scrapeSinglePerformer?.first ?? candidate
    }

    // MARK: - Editable snapshots (fetched fresh by the sheets; richer than the app's list models)

    struct StashIDPair: Codable, Sendable, Hashable {
        let endpoint: String
        let stash_id: String
    }

    struct SceneEditData: Decodable, Sendable {
        struct Entity: Decodable, Sendable, Hashable { let id: String; let name: String }
        struct Paths: Decodable, Sendable { let screenshot: String? }
        let id: String
        let title: String?
        let details: String?
        let date: String?
        let urls: [String]?
        let studio: Entity?
        let performers: [Entity]?
        let tags: [Entity]?
        let stash_ids: [StashIDPair]?
        let paths: Paths?
    }

    func sceneEditData(id: String) async throws -> SceneEditData? {
        struct Vars: Encodable, Sendable { let id: String }
        struct Resp: Decodable, Sendable { let findScene: SceneEditData? }
        let gql = """
        query SceneEditData($id: ID!) {
          findScene(id: $id) {
            id title details date urls
            studio { id name }
            performers { id name }
            tags { id name }
            stash_ids { endpoint stash_id }
            paths { screenshot }
          }
        }
        """
        let resp: Resp = try await client.query(gql, variables: Vars(id: id))
        return resp.findScene
    }

    struct PerformerEditData: Decodable, Sendable {
        let id: String
        let name: String?
        let disambiguation: String?
        let gender: String?
        let birthdate: String?
        let death_date: String?
        let ethnicity: String?
        let country: String?
        let eye_color: String?
        let hair_color: String?
        let height_cm: Int?
        let weight: Int?
        let measurements: String?
        let tattoos: String?
        let piercings: String?
        let details: String?
        let urls: [String]?
        let alias_list: [String]?
        let stash_ids: [StashIDPair]?
        let image_path: String?
    }

    func performerEditData(id: String) async throws -> PerformerEditData? {
        struct Vars: Encodable, Sendable { let id: String }
        struct Resp: Decodable, Sendable { let findPerformer: PerformerEditData? }
        let gql = """
        query PerformerEditData($id: ID!) {
          findPerformer(id: $id) {
            id name disambiguation gender birthdate death_date ethnicity country eye_color hair_color
            height_cm weight measurements tattoos piercings details urls alias_list
            stash_ids { endpoint stash_id }
            image_path
          }
        }
        """
        let resp: Resp = try await client.query(gql, variables: Vars(id: id))
        return resp.findPerformer
    }

    /// Re-fetch a performer in the app's standard shape (same selection as the library queries) so the
    /// detail screen can refresh after an edit.
    func findPerformer(id: String) async throws -> Performer? {
        struct Vars: Encodable, Sendable { let id: String }
        struct Resp: Decodable, Sendable { let findPerformer: Performer? }
        let gql = """
        query FindPerformer($id: ID!) {
          findPerformer(id: $id) {
            id name image_path rating100 favorite scene_count country birthdate gender urls tags { id name }
          }
        }
        """
        let resp: Resp = try await client.query(gql, variables: Vars(id: id))
        return resp.findPerformer
    }

    // MARK: - Mutations

    /// Partial scene update: nil fields are omitted from the JSON (synthesized Encodable uses
    /// encodeIfPresent), which Stash treats as "leave unchanged". Set list fields to the FULL new list.
    struct SceneEdit: Encodable, Sendable {
        let id: String
        var title: String?
        var details: String?
        var date: String?
        var urls: [String]?
        var studio_id: String?
        var performer_ids: [String]?
        var tag_ids: [String]?
        var cover_image: String?
        var stash_ids: [StashIDPair]?
    }

    func updateScene(_ edit: SceneEdit) async throws {
        struct Vars: Encodable, Sendable { let input: SceneEdit }
        struct Result: Decodable, Sendable { let id: String }
        struct Resp: Decodable, Sendable { let sceneUpdate: Result? }
        let gql = "mutation SceneUpdate($input: SceneUpdateInput!) { sceneUpdate(input: $input) { id } }"
        let resp: Resp = try await client.query(gql, variables: Vars(input: edit))
        guard resp.sceneUpdate != nil else { throw StashError.graphqlError("Scene update failed") }
    }

    struct PerformerEdit: Encodable, Sendable {
        let id: String
        var name: String?
        var disambiguation: String?
        var gender: String?           // GenderEnum name — must be a valid case or nil (see genderEnum)
        var birthdate: String?
        var death_date: String?
        var ethnicity: String?
        var country: String?
        var eye_color: String?
        var hair_color: String?
        var height_cm: Int?
        var weight: Int?
        var measurements: String?
        var tattoos: String?
        var piercings: String?
        var details: String?
        var urls: [String]?
        var alias_list: [String]?
        var image: String?            // URL or base64 data URL
        var stash_ids: [StashIDPair]?
    }

    func updatePerformer(_ edit: PerformerEdit) async throws {
        struct Vars: Encodable, Sendable { let input: PerformerEdit }
        struct Result: Decodable, Sendable { let id: String }
        struct Resp: Decodable, Sendable { let performerUpdate: Result? }
        let gql = "mutation PerformerUpdate($input: PerformerUpdateInput!) { performerUpdate(input: $input) { id } }"
        let resp: Resp = try await client.query(gql, variables: Vars(input: edit))
        guard resp.performerUpdate != nil else { throw StashError.graphqlError("Performer update failed") }
    }

    struct PerformerCreate: Encodable, Sendable {
        let name: String
        var disambiguation: String?
        var gender: String?
        var birthdate: String?
        var death_date: String?
        var ethnicity: String?
        var country: String?
        var eye_color: String?
        var hair_color: String?
        var height_cm: Int?
        var weight: Int?
        var measurements: String?
        var tattoos: String?
        var piercings: String?
        var details: String?
        var urls: [String]?
        var alias_list: [String]?
        var image: String?
        var stash_ids: [StashIDPair]?
    }

    /// Create a performer; returns the new local id.
    @discardableResult
    func createPerformer(_ input: PerformerCreate) async throws -> String {
        struct Vars: Encodable, Sendable { let input: PerformerCreate }
        struct Result: Decodable, Sendable { let id: String }
        struct Resp: Decodable, Sendable { let performerCreate: Result? }
        let gql = "mutation PerformerCreate($input: PerformerCreateInput!) { performerCreate(input: $input) { id } }"
        let resp: Resp = try await client.query(gql, variables: Vars(input: input))
        guard let created = resp.performerCreate else { throw StashError.graphqlError("Performer create failed") }
        return created.id
    }

    /// Create a tag by name (for scraped tags that don't exist locally); returns the new id.
    func createTag(name: String) async throws -> String {
        struct Input: Encodable, Sendable { let name: String }
        struct Vars: Encodable, Sendable { let input: Input }
        struct Result: Decodable, Sendable { let id: String }
        struct Resp: Decodable, Sendable { let tagCreate: Result? }
        let gql = "mutation TagCreate($input: TagCreateInput!) { tagCreate(input: $input) { id } }"
        let resp: Resp = try await client.query(gql, variables: Vars(input: Input(name: name)))
        guard let created = resp.tagCreate else { throw StashError.graphqlError("Tag create failed") }
        return created.id
    }

    /// Create a studio by name (for a scraped studio that doesn't exist locally); returns the new id.
    func createStudio(name: String) async throws -> String {
        struct Input: Encodable, Sendable { let name: String }
        struct Vars: Encodable, Sendable { let input: Input }
        struct Result: Decodable, Sendable { let id: String }
        struct Resp: Decodable, Sendable { let studioCreate: Result? }
        let gql = "mutation StudioCreate($input: StudioCreateInput!) { studioCreate(input: $input) { id } }"
        let resp: Resp = try await client.query(gql, variables: Vars(input: Input(name: name)))
        guard let created = resp.studioCreate else { throw StashError.graphqlError("Studio create failed") }
        return created.id
    }

    // MARK: - Mapping helpers (mirror Stash's scrapedPerformerToCreateInput)

    /// Normalize a scraped gender string to a GenderEnum case name, or nil when it doesn't map —
    /// sending an invalid enum value fails GraphQL validation, so unknown strings are dropped.
    static func genderEnum(from scraped: String?) -> String? {
        guard let scraped, !scraped.isEmpty else { return nil }
        let normalized = scraped.uppercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        let valid = ["MALE", "FEMALE", "TRANSGENDER_MALE", "TRANSGENDER_FEMALE", "INTERSEX", "NON_BINARY"]
        return valid.contains(normalized) ? normalized : nil
    }

    /// Merge a stash-box linkage into an existing list, replacing any entry for the same endpoint —
    /// how Stash's UI maintains `stash_ids` after a scrape.
    static func mergedStashIDs(existing: [StashIDPair]?, endpoint: String?, remoteID: String?) -> [StashIDPair]? {
        guard let endpoint, let remoteID, !remoteID.isEmpty else { return nil }
        var out = (existing ?? []).filter { $0.endpoint.caseInsensitiveCompare(endpoint) != .orderedSame }
        out.append(StashIDPair(endpoint: endpoint, stash_id: remoteID))
        return out
    }
}
