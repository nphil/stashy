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
        // Owner decision (2026-07-24): only StashDB / ThePornDB / FansDB are useful — everything else is
        // dropped. Match on name OR endpoint so a box named "Stash" pointed at stashdb.org still qualifies.
        var out: [Source] = (resp.configuration.general.stashBoxes ?? []).enumerated().compactMap { i, box in
            guard Self.isAllowed(name: box.name, endpoint: box.endpoint) else { return nil }
            return Source(kind: .stashBox(endpoint: box.endpoint),
                          name: box.name.isEmpty ? "Stash-Box #\(i + 1)" : box.name)
        }
        out += (resp.listScrapers ?? [])
            .filter { capability($0) && Self.isAllowed(name: $0.name, endpoint: nil) }
            .map { Source(kind: .scraper(id: $0.id), name: $0.name) }
        // Priority order for conflict defaults + display: StashDB, then ThePornDB, then FansDB.
        return out.sorted { Self.rank($0) < Self.rank($1) }
    }

    /// The only three sources the owner keeps. Keyword-matched against name + endpoint (case-insensitive).
    private static let allowedKeywords = ["stashdb", "theporndb", "porndb", "tpdb", "fansdb"]

    static func isAllowed(name: String, endpoint: String?) -> Bool {
        let hay = (name + " " + (endpoint ?? "")).lowercased()
        return allowedKeywords.contains { hay.contains($0) }
    }

    /// Conflict-resolution + display priority: StashDB (0) → ThePornDB (1) → FansDB (2). When two sources
    /// disagree on a field, the lower rank wins the default.
    static func rank(_ source: Source) -> Int {
        var hay = source.name.lowercased()
        if case .stashBox(let endpoint) = source.kind { hay += " " + endpoint.lowercased() }
        if hay.contains("stashdb") { return 0 }
        if hay.contains("theporndb") || hay.contains("porndb") || hay.contains("tpdb") { return 1 }
        if hay.contains("fansdb") { return 2 }
        return 3
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

    // MARK: - Auto multi-source scrape (query all 3 configured sources at once)

    struct SourcedScene: Sendable { let source: Source; let scene: ScrapedSceneData }
    struct SourcedPerformer: Sendable, Identifiable {
        let source: Source
        let candidate: ScrapedPerformerData
        var id: String { "\(source.id)|\(candidate.id)" }
    }

    /// No allowed sources are configured on the server — surfaced so the sheet can tell the user to add a
    /// stash-box in Stash rather than showing a bare "no match".
    struct NoSourcesError: LocalizedError { var errorDescription: String? {
        "No StashDB / ThePornDB / FansDB source is configured on your Stash server."
    } }

    /// The outcome of querying every allowed source: what came back, and which sources were UNREACHABLE
    /// (errored / timed out). A source that simply had no match is neither in `items` nor in `failed`.
    /// This lets the sheet tell "nothing matched" apart from "the source is down", and note a partial
    /// failure ("merged what was found; FansDB was unreachable") when only some sources answered.
    struct MultiSourceResult<Item: Sendable>: Sendable {
        let items: [Item]
        let failed: [String]     // display names of sources that errored
    }

    /// Scrape a stored scene against EVERY allowed source in parallel, one best match per source (scene
    /// fingerprint matches are unique). A source that ERRORS is recorded in `failed` (so "unreachable" is
    /// distinguishable from "no match") but never blocks the others. Matches are priority-ordered. Throws
    /// only when the source list itself can't be read or no allowed source exists.
    func scrapeSceneEverywhere(sceneID: String) async throws -> MultiSourceResult<SourcedScene> {
        let sources = try await sceneSources()
        guard !sources.isEmpty else { throw NoSourcesError() }
        let outcomes = await withTaskGroup(of: (SourcedScene?, String?).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        if let first = try await self.scrapeScene(source: source, sceneID: sceneID).first {
                            return (SourcedScene(source: source, scene: first), nil)
                        }
                        return (nil, nil)                    // reached, no match
                    } catch {
                        return (nil, source.name)            // unreachable / errored
                    }
                }
            }
            var acc: [(SourcedScene?, String?)] = []
            for await outcome in group { acc.append(outcome) }
            return acc
        }
        let matches = outcomes.compactMap { $0.0 }.sorted { Self.rank($0.source) < Self.rank($1.source) }
        return MultiSourceResult(items: matches, failed: outcomes.compactMap { $0.1 })
    }

    /// Search performers by name against EVERY allowed source in parallel; returns every candidate tagged
    /// with its source, plus the names of any sources that errored. Group `items` with `groupPerformers`.
    func searchPerformersEverywhere(name: String) async throws -> MultiSourceResult<SourcedPerformer> {
        let sources = try await performerSources()
        guard !sources.isEmpty else { throw NoSourcesError() }
        let outcomes = await withTaskGroup(of: ([SourcedPerformer], String?).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let found = try await self.searchPerformers(source: source, name: name)
                        return (found.map { SourcedPerformer(source: source, candidate: $0) }, nil)
                    } catch {
                        return ([], source.name)             // unreachable / errored
                    }
                }
            }
            var acc: [([SourcedPerformer], String?)] = []
            for await outcome in group { acc.append(outcome) }
            return acc
        }
        return MultiSourceResult(items: outcomes.flatMap { $0.0 }, failed: outcomes.compactMap { $0.1 })
    }

    /// One merged candidate the picker shows: the same person as reported by one or more sources. Same
    /// name + birthdate collapses into one row; a different name or birthdate stays separate so the user
    /// picks manually. Contributors are priority-ordered.
    struct MergedPerformerCandidate: Identifiable, Sendable {
        let id: String
        let name: String
        let disambiguation: String?
        let birthdate: String?
        let country: String?
        let previewImage: String?
        let contributors: [SourcedPerformer]
        var sourceNames: [String] { contributors.map(\.source.name) }
    }

    /// Group flat candidates by likely-same-person (lowercased name + birthdate), preserving first-seen
    /// order; contributors within a group are priority-ordered. Candidates with no name are dropped.
    static func groupPerformers(_ items: [SourcedPerformer]) -> [MergedPerformerCandidate] {
        var order: [String] = []
        var groups: [String: [SourcedPerformer]] = [:]
        for item in items {
            guard let name = item.candidate.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let key = name.lowercased() + "|" + (item.candidate.birthdate ?? "")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { key in
            let contributors = groups[key]!.sorted { rank($0.source) < rank($1.source) }
            let primary = contributors.first!.candidate
            let preview = contributors.compactMap { $0.candidate.images?.first }.first
            return MergedPerformerCandidate(
                id: key, name: primary.name ?? "Unknown", disambiguation: primary.disambiguation,
                birthdate: primary.birthdate, country: primary.country, previewImage: preview,
                contributors: contributors)
        }
    }

    /// Full detail merged across every source that reported this person. Fields resolve in priority order
    /// (StashDB wins), images union (priority-ordered, deduped), and one stash_id per stash-box source.
    struct ResolvedPerformer: Sendable {
        /// Priority-ordered full records (index 0 = highest priority). Apply reversed into a draft so the
        /// highest-priority non-empty value wins.
        let ordered: [ScrapedPerformerData]
        let images: [String]
        let stashIDs: [StashIDPair]
    }

    func resolvePerformer(_ candidate: MergedPerformerCandidate) async -> ResolvedPerformer {
        let sorted = candidate.contributors.sorted { Self.rank($0.source) < Self.rank($1.source) }
        let details: [ScrapedPerformerData] = await withTaskGroup(of: (Int, ScrapedPerformerData).self) { group in
            for (index, contributor) in sorted.enumerated() {
                group.addTask {
                    let full = (try? await self.performerDetail(source: contributor.source, candidate: contributor.candidate))
                        ?? contributor.candidate
                    return (index, full)
                }
            }
            var acc: [(Int, ScrapedPerformerData)] = []
            for await result in group { acc.append(result) }
            return acc.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        var images: [String] = []
        for record in details {
            for image in record.images ?? [] where !images.contains(image) { images.append(image) }
        }
        var stashIDs: [StashIDPair] = []
        for contributor in sorted {
            guard case .stashBox(let endpoint) = contributor.source.kind,
                  let remoteID = contributor.candidate.remote_site_id, !remoteID.isEmpty else { continue }
            stashIDs.removeAll { $0.endpoint.caseInsensitiveCompare(endpoint) == .orderedSame }
            stashIDs.append(StashIDPair(endpoint: endpoint, stash_id: remoteID))
        }
        return ResolvedPerformer(ordered: details, images: images, stashIDs: stashIDs)
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

    /// Human-readable join of source names for an error/note ("StashDB", "StashDB and FansDB",
    /// "StashDB, ThePornDB, and FansDB").
    static func sourceList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
    }
}
