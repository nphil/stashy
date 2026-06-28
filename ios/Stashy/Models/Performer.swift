import Foundation

struct Performer: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let image_path: String?
    let rating100: Int?
    let scene_count: Int?
    let country: String?
    let birthdate: String?
    let gender: String?
    let urls: [String]?

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

    /// Star rating on a 0–5 scale (Stash stores rating100 as 0–100).
    var ratingStars: Double? {
        guard let r = rating100 else { return nil }
        return Double(r) / 20.0
    }

    /// Age in years computed from birthdate ("yyyy-MM-dd").
    var age: Int? {
        guard let birthdate, !birthdate.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: birthdate) else { return nil }
        return Calendar.current.dateComponents([.year], from: date, to: Date()).year
    }
}
