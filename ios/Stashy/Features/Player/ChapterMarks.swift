import Foundation

/// A scene's Stash markers as the progress bar shows them: a cut at each marker's start, and the marker's name
/// while the thumb is in it (from its start until the next one starts). A scene with no markers has none of it.
///
/// Built once per scene; every lookup after that is a binary search over the stored starts, so asking per scrub
/// event allocates nothing.
struct ChapterMarks: Sendable, Equatable {
    /// Start of each marker in seconds, ascending, one per start.
    let starts: [Double]
    private let names: [String]

    init() {
        starts = []
        names = []
    }

    init(_ markers: [SceneMarker]?) {
        var begins: [Double] = []
        var labels: [String] = []
        let ordered = (markers ?? []).filter { $0.seconds.isFinite && $0.seconds >= 0 }.sorted { $0.seconds < $1.seconds }
        for marker in ordered where marker.seconds != begins.last {
            begins.append(marker.seconds)
            labels.append(Self.label(for: marker, position: labels.count + 1))
        }
        starts = begins
        names = labels
    }

    /// The marker's title; Stash lets it be empty, and then its primary tag is what names it.
    private static func label(for marker: SceneMarker, position: Int) -> String {
        let title = marker.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        let tag = marker.primary_tag?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tag.isEmpty ? "Marker \(position)" : tag
    }

    /// Whether the scene has markers to show.
    var isShown: Bool { !starts.isEmpty }

    /// Which marker `time` falls in: the last one that starts at or before it; -1 before the first one.
    func index(at time: TimeInterval) -> Int {
        guard time.isFinite else { return -1 }
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= time { low = middle + 1 } else { high = middle }
        }
        return low - 1
    }

    /// The name of the marker `time` falls in; nil before the first marker.
    func name(at time: TimeInterval) -> String? {
        let position = index(at: time)
        return position >= 0 ? names[position] : nil
    }
}
