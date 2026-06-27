import Foundation

struct Performer: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let image_path: String?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Performer, rhs: Performer) -> Bool { lhs.id == rhs.id }

    func imageURL(apiKey: String) -> URL? {
        guard let path = image_path else { return nil }
        guard var components = URLComponents(string: path) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "apikey" }
        items.append(URLQueryItem(name: "apikey", value: apiKey))
        components.queryItems = items
        return components.url
    }
}
