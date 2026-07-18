import SwiftUI

/// A caption label above a full-width control — keeps segmented pickers self-explanatory without a side
/// label squeezing them (which caused menu wrapping/truncation). Shared by the Downloads staging card and
/// the bulk-download sheet, which previously carried byte-identical private `labeledSegment` copies.
struct LabeledSegment<Content: View>: View {
    private let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            content
        }
    }
}
