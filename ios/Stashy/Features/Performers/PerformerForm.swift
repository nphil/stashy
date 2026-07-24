import SwiftUI
import PhotosUI

/// The editable performer fields, shared by the performer edit sheet and the add-performer flow.
/// Mirrors Stash's own `scrapedPerformerToCreateInput` mapping: comma-joined aliases split to a list,
/// height/weight numeric-converted, gender normalized to the enum (invalid strings dropped).
struct PerformerDraft: Equatable {
    var name = ""
    var disambiguation = ""
    var gender = ""            // GenderEnum case name ("FEMALE"…) or "" for unset
    var birthdate = ""
    var deathDate = ""
    var country = ""
    var ethnicity = ""
    var eyeColor = ""
    var hairColor = ""
    var heightCm = ""          // numeric text fields; converted on save
    var weight = ""
    var measurements = ""
    var tattoos = ""
    var piercings = ""
    var details = ""
    var urls: [String] = []
    var aliases: [String] = []

    init() {}

    /// Seed from a fresh server fetch (the edit flow).
    init(data: StashScraper.PerformerEditData) {
        name = data.name ?? ""
        disambiguation = data.disambiguation ?? ""
        gender = StashScraper.genderEnum(from: data.gender) ?? ""
        birthdate = data.birthdate ?? ""
        deathDate = data.death_date ?? ""
        country = data.country ?? ""
        ethnicity = data.ethnicity ?? ""
        eyeColor = data.eye_color ?? ""
        hairColor = data.hair_color ?? ""
        heightCm = data.height_cm.map(String.init) ?? ""
        weight = data.weight.map(String.init) ?? ""
        measurements = data.measurements ?? ""
        tattoos = data.tattoos ?? ""
        piercings = data.piercings ?? ""
        details = data.details ?? ""
        urls = data.urls ?? []
        aliases = data.alias_list ?? []
    }

    /// Seed from a scraped record (the create flow).
    init(scraped: StashScraper.ScrapedPerformerData) {
        var draft = PerformerDraft()
        draft.merge(scraped: scraped)
        self = draft
    }

    /// Stash's merge rule: a non-empty scraped value overwrites, an empty one never clears.
    mutating func merge(scraped: StashScraper.ScrapedPerformerData) {
        func take(_ value: String?, into field: inout String) {
            if let value, !value.isEmpty { field = value }
        }
        take(scraped.name, into: &name)
        take(scraped.disambiguation, into: &disambiguation)
        if let g = StashScraper.genderEnum(from: scraped.gender) { gender = g }
        take(scraped.birthdate, into: &birthdate)
        take(scraped.death_date, into: &deathDate)
        take(scraped.country, into: &country)
        take(scraped.ethnicity, into: &ethnicity)
        take(scraped.eye_color, into: &eyeColor)
        take(scraped.hair_color, into: &hairColor)
        take(scraped.height, into: &heightCm)
        take(scraped.weight, into: &weight)
        take(scraped.measurements, into: &measurements)
        take(scraped.tattoos, into: &tattoos)
        take(scraped.piercings, into: &piercings)
        take(scraped.details, into: &details)
        if let u = scraped.urls, !u.isEmpty { urls = Array(Set(urls).union(u)).sorted() }
        if let a = scraped.aliases, !a.isEmpty {
            // Schema comment: aliases are comma-delimited in one string.
            let split = a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            aliases = Array(Set(aliases).union(split.filter { !$0.isEmpty })).sorted()
        }
    }

    private func opt(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    func createInput(stashIDs: [StashScraper.StashIDPair]?, image: String?) -> StashScraper.PerformerCreate {
        var input = StashScraper.PerformerCreate(name: name.trimmingCharacters(in: .whitespaces))
        input.disambiguation = opt(disambiguation)
        input.gender = opt(gender)
        input.birthdate = opt(birthdate)
        input.death_date = opt(deathDate)
        input.country = opt(country)
        input.ethnicity = opt(ethnicity)
        input.eye_color = opt(eyeColor)
        input.hair_color = opt(hairColor)
        input.height_cm = Int(heightCm.trimmingCharacters(in: .whitespaces))
        input.weight = Int(weight.trimmingCharacters(in: .whitespaces))
        input.measurements = opt(measurements)
        input.tattoos = opt(tattoos)
        input.piercings = opt(piercings)
        input.details = opt(details)
        input.urls = urls.isEmpty ? nil : urls
        input.alias_list = aliases.isEmpty ? nil : aliases
        input.image = image
        input.stash_ids = stashIDs
        return input
    }

    func updateInput(id: String, stashIDs: [StashScraper.StashIDPair]?, image: String?) -> StashScraper.PerformerEdit {
        var edit = StashScraper.PerformerEdit(id: id)
        edit.name = opt(name)                       // omit an emptied name (name is required in Stash)
        edit.disambiguation = disambiguation
        edit.gender = opt(gender)
        // Dates are omitted when empty (Stash rejects "" as an invalid date; clearing isn't supported here).
        edit.birthdate = opt(birthdate)
        edit.death_date = opt(deathDate)
        edit.country = country
        edit.ethnicity = ethnicity
        edit.eye_color = eyeColor
        edit.hair_color = hairColor
        edit.height_cm = Int(heightCm.trimmingCharacters(in: .whitespaces))
        edit.weight = Int(weight.trimmingCharacters(in: .whitespaces))
        edit.measurements = measurements
        edit.tattoos = tattoos
        edit.piercings = piercings
        edit.details = details
        edit.urls = urls
        edit.alias_list = aliases
        edit.image = image
        edit.stash_ids = stashIDs
        return edit
    }
}

/// The performer field stack — every editable field in one scrollable column, grouped so the medium
/// detent shows identity fields first and detail fields under one flick.
struct PerformerFormFields: View {
    @Binding var draft: PerformerDraft
    @Environment(ThemeManager.self) private var themeManager

    private static let genders: [(value: String, label: String)] = [
        ("", "Not set"),
        ("FEMALE", "Female"),
        ("MALE", "Male"),
        ("TRANSGENDER_FEMALE", "Transgender female"),
        ("TRANSGENDER_MALE", "Transgender male"),
        ("NON_BINARY", "Non-binary"),
        ("INTERSEX", "Intersex"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditFieldRow(label: "Name", placeholder: "Name", text: $draft.name)
            EditFieldRow(label: "Disambiguation", placeholder: "Optional", text: $draft.disambiguation)

            HStack(spacing: 10) {
                EditFieldRow(label: "Birthdate", placeholder: "YYYY-MM-DD", text: $draft.birthdate,
                             keyboard: .numbersAndPunctuation)
                EditFieldRow(label: "Country", placeholder: "US", text: $draft.country)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Gender")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(Self.genders, id: \.value) { option in
                        Button(option.label) { draft.gender = option.value }
                    }
                } label: {
                    HStack {
                        Text(Self.genders.first { $0.value == draft.gender }?.label ?? "Not set")
                            .font(.subheadline)
                            .foregroundStyle(themeManager.current.foregroundColor)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .capsuleField(foreground: themeManager.current.foregroundColor)
                }
            }

            HStack(spacing: 10) {
                EditFieldRow(label: "Height (cm)", placeholder: "170", text: $draft.heightCm,
                             keyboard: .numberPad)
                EditFieldRow(label: "Weight (kg)", placeholder: "55", text: $draft.weight,
                             keyboard: .numberPad)
            }

            HStack(spacing: 10) {
                EditFieldRow(label: "Eye color", placeholder: "", text: $draft.eyeColor)
                EditFieldRow(label: "Hair color", placeholder: "", text: $draft.hairColor)
            }

            EditFieldRow(label: "Ethnicity", placeholder: "", text: $draft.ethnicity)
            EditFieldRow(label: "Measurements", placeholder: "", text: $draft.measurements)
            EditFieldRow(label: "Tattoos", placeholder: "", text: $draft.tattoos)
            EditFieldRow(label: "Piercings", placeholder: "", text: $draft.piercings)

            VStack(alignment: .leading, spacing: 5) {
                Text("Details")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.details)
                    .font(.subheadline)
                    .frame(minHeight: 60, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeManager.current.foregroundColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            urlList
        }
    }

    @ViewBuilder private var urlList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Links")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if draft.urls.isEmpty {
                Text("No links")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(draft.urls, id: \.self) { url in
                        MetaChip(
                            name: URL(string: url)?.host() ?? url,
                            matched: true,
                            onRemove: { draft.urls.removeAll { $0 == url } }
                        )
                    }
                }
            }
        }
    }
}

/// Horizontal photo strip for a performer — scraped candidate images PLUS a native "upload" tile
/// (`PhotosPicker`) so the user can supply their own picture. The chosen one gets the accent ring and is
/// sent to Stash as the performer image (base64 data URL for an upload, or the scraped URL/data URL —
/// both accepted). An uploaded photo is downscaled + JPEG-encoded off-main and prepended, auto-selected.
struct PerformerPhotoPicker: View {
    /// All candidate images (scraped + uploaded data URLs). Uploads prepend here.
    @Binding var images: [String]
    @Binding var selected: String?
    @Environment(ThemeManager.self) private var themeManager
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Photo")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        VStack(spacing: 5) {
                            if uploading {
                                ProgressView()
                            } else {
                                Image(systemName: "photo.badge.plus")
                                    .font(.title3)
                                Text("Upload")
                                    .font(.caption2.weight(.medium))
                            }
                        }
                        .foregroundStyle(themeManager.current.accentColor)
                        .frame(width: 84, height: 112)
                        .background(themeManager.current.accentColor.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(themeManager.current.accentColor.opacity(0.4),
                                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        ScrapedImageView(source: image)
                            .frame(width: 84, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        selected == image ? themeManager.current.accentColor : .clear,
                                        lineWidth: 2.5
                                    )
                            }
                            .overlay(alignment: .topTrailing) {
                                if selected == image {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.subheadline)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, themeManager.current.accentColor)
                                        .padding(4)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onTapGesture {
                                selected = selected == image ? nil : image
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .task(id: pickerItem) {
            guard let pickerItem else { return }
            uploading = true
            defer { uploading = false }
            guard let data = try? await pickerItem.loadTransferable(type: Data.self),
                  let dataURL = await ImageUpload.dataURL(from: data) else { return }
            images.insert(dataURL, at: 0)
            selected = dataURL
            self.pickerItem = nil
        }
    }
}
