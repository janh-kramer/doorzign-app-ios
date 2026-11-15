import DoorZignAPI
import DoorZignCore
import SwiftUI

/// „Aus Bibliothek“ (ui-spec §4, Feature `media.library`): Raster aus `GET /media`, Auswahl übernimmt `mediaId`.
/// Texte als `LocalizedStringKey`, damit sie in den String-Katalog wandern (Englisch folgt).
struct MediaLibraryView: View {
    let selectedId: String?
    let onSelect: (String) -> Void
    @State private var model: MediaLibraryModel
    @Environment(\.dismiss) private var dismiss

    init(client: Client, selectedId: String?, onSelect: @escaping (String) -> Void) {
        self.selectedId = selectedId
        self.onSelect = onSelect
        _model = State(initialValue: MediaLibraryModel(client: client))
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        NavigationStack {
            Group {
                if let error = model.error, model.items.isEmpty {
                    ContentUnavailableView {
                        Label("Bibliothek nicht verfügbar", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text(error.message)
                    } actions: {
                        Button("Erneut versuchen") { Task { await model.load() } }
                    }
                } else if !model.hasLoaded {
                    ProgressView()
                } else if model.items.isEmpty {
                    ContentUnavailableView("Keine Bilder", systemImage: "photo.on.rectangle",
                                           description: Text("In der Bibliothek sind noch keine Bilder vorhanden."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(model.items, id: \.id) { media in
                                Button {
                                    onSelect(media.id)
                                    dismiss()
                                } label: {
                                    MediaThumbnail(media: media, loader: model.thumbnails, isSelected: media.id == selectedId)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Bibliothek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .task { if !model.hasLoaded { await model.load() } }
            .refreshable { await model.load() }
        }
    }
}

/// Quadratische Miniatur; lädt über den `MediaThumbnailLoader` (mit Bearer).
private struct MediaThumbnail: View {
    let media: Media
    let loader: MediaThumbnailLoader
    let isSelected: Bool
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title3)
                        .padding(6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(media.fileName ?? String(localized: "Bild")))
            .accessibilityValue(Text("\(media.width) × \(media.height)"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .task(id: media.id) {
                guard image == nil else { return }
                if let data = await loader.thumbnail(for: media.id), let loaded = UIImage(data: data) {
                    image = loaded
                } else {
                    failed = true
                }
            }
    }
}
