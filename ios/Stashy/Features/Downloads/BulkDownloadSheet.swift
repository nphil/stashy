import SwiftUI

/// Options sheet for a bulk download — pick ONE quality for the whole batch. Friendly one-tap presets up
/// top, with an expandable Advanced section (same segmented pickers as the per-scene card). Purely additive:
/// presented from the library; it never alters the existing per-scene staging UI.
struct BulkDownloadSheet: View {
    /// How many scenes will be queued (for the header + confirm button).
    let sceneCount: Int
    /// Called with the chosen options when the user taps Download; the sheet then dismisses.
    let onConfirm: (BulkDownloadOptions) -> Void

    @Environment(\.dismiss) private var dismiss

    // Sheet state = the advanced fields; the active preset is derived by comparing to them.
    @State private var transcode = true
    @State private var codec: StashCompanion.Codec = .hevc
    @State private var resolution: ServerQuality = .p1080
    @State private var quality: CompanionQuality = .medium
    @State private var advancedExpanded = false

    /// Persist the last-used choice so the next bulk download defaults to it.
    @AppStorage("bulk.download.transcode") private var savedTranscode = true
    @AppStorage("bulk.download.codec") private var savedCodec = StashCompanion.Codec.hevc.rawValue
    @AppStorage("bulk.download.resolution") private var savedResolution = ServerQuality.p1080.rawValue
    @AppStorage("bulk.download.quality") private var savedQuality = CompanionQuality.medium.rawValue

    private var options: BulkDownloadOptions {
        transcode ? .init(source: .companion(codec, resolution, quality)) : .original
    }

    private let presets: [(label: String, subtitle: String, symbol: String, opts: BulkDownloadOptions)] = [
        ("720p data-saver", "Smallest · HEVC · best for slow links", "antenna.radiowaves.left.and.right", .dataSaver720),
        ("iPhone 1080p", "Balanced · HEVC · everyday travel pick", "iphone", .iphone1080),
        ("Original file", "Full quality · largest · no server wait", "film", .original),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Quality") {
                    ForEach(presets, id: \.label) { preset in
                        Button { apply(preset.opts) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.symbol)
                                    .font(.title3).frame(width: 28)
                                    .foregroundStyle(options == preset.opts ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.label).font(.body)
                                    Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if options == preset.opts {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                        Picker("Source", selection: $transcode) {
                            Text("Original").tag(false)
                            Text("Transcode").tag(true)
                        }
                        .pickerStyle(.segmented)

                        if transcode {
                            LabeledSegment("Codec") {
                                Picker("Codec", selection: $codec) {
                                    ForEach(StashCompanion.Codec.allCases) { Text($0.label).tag($0) }
                                }.pickerStyle(.segmented)
                            }
                            LabeledSegment("Resolution") {
                                Picker("Resolution", selection: $resolution) {
                                    ForEach([ServerQuality.original, .p1080, .p720, .p480]) { Text($0.label).tag($0) }
                                }.pickerStyle(.segmented)
                            }
                            LabeledSegment("Quality") {
                                Picker("Quality", selection: $quality) {
                                    ForEach(CompanionQuality.allCases) { Text($0.label).tag($0) }
                                }.pickerStyle(.segmented)
                            }
                        }
                    }
                } footer: {
                    if options.isTranscode {
                        Text("Transcodes run one at a time on your server, so a large batch fills in gradually. Originals download in parallel.")
                    }
                }
            }
            .navigationTitle("Download \(sceneCount) scene\(sceneCount == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { save(); onConfirm(options); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear(perform: restore)
    }

    private func apply(_ opts: BulkDownloadOptions) {
        switch opts.source {
        case .original: transcode = false
        case .companion(let c, let r, let q): transcode = true; codec = c; resolution = r; quality = q
        case .serverH264(let r): transcode = true; resolution = r
        }
    }

    private func restore() {
        transcode = savedTranscode
        codec = StashCompanion.Codec(rawValue: savedCodec) ?? .hevc
        resolution = ServerQuality(rawValue: savedResolution) ?? .p1080
        quality = CompanionQuality(rawValue: savedQuality) ?? .medium
    }

    private func save() {
        savedTranscode = transcode
        savedCodec = codec.rawValue
        savedResolution = resolution.rawValue
        savedQuality = quality.rawValue
    }
}
