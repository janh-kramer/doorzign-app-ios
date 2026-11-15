import DoorZignAPI
import DoorZignCore
import PhotosUI
import SwiftUI

/// Ansicht bearbeiten (ui-spec §4): Typwahl, Text/Bild/Kalender, Live-Vorschau, Speichern mit If-Match.
struct SlotEditorView: View {
    let onSaved: () -> Void
    @State private var model: SlotEditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDiscard = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showLibrary = false
    private let client: Client

    init(context: SignedInContext, displayId: String, slot: Int, display: Display?, onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        self.client = context.client
        _model = State(initialValue: SlotEditorModel(
            displayId: displayId, slot: slot, display: display,
            client: context.client, system: context.system
        ))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if let error = model.loadError {
                ErrorSection(message: error.message)
            } else if model.original == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else {
                previewSection
                if model.isReadOnly {
                    readOnlySection
                } else {
                    kindSection
                    switch model.draft.kind {
                    case .text: textSections
                    case .image: imageSections
                    case .calendar: calendarSections
                    case .deactivated: deactivatedSection
                    }
                }
                if let error = model.saveError {
                    Section {
                        Text(error.message).foregroundStyle(.red)
                        ForEach(error.fields.sorted(by: { $0.key < $1.key }), id: \.key) { field, messages in
                            ForEach(messages, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Ansicht \(model.slotNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isDirty)
        .toolbar {
            if model.isDirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { confirmDiscard = true }
                }
            }
            if !model.isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button("Speichern") { Task { await save() } }
                            .disabled(!model.canSave)
                    }
                }
            }
        }
        .task { if model.original == nil { await model.load() } }
        .onChange(of: model.draft) { model.schedulePreview() }
        .confirmationDialog("Änderungen verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) { dismiss() }
        } message: {
            Text("Die Änderungen an dieser Ansicht wurden noch nicht gespeichert.")
        }
        .alert("Inzwischen von jemand anderem geändert", isPresented: Binding(
            get: { model.hasConflict }, set: { if !$0 { model.dismissConflict() } }
        )) {
            Button("Neu laden") { Task { await model.reloadDiscardingChanges() } }
            Button("Überschreiben", role: .destructive) { Task { await save(overwrite: true) } }
            Button("Abbrechen", role: .cancel) { model.dismissConflict() }
        } message: {
            Text("Neu laden verwirft deine Änderungen. Überschreiben ersetzt die Änderungen der anderen Person.")
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in Task { await model.uploadImage(data) } }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showLibrary) {
            MediaLibraryView(client: client, selectedId: model.draft.image.mediaId) { mediaId in
                model.selectMedia(mediaId)
            }
        }
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.uploadImage(data)
                }
            }
        }
    }

    private func save(overwrite: Bool = false) async {
        if await model.save(overwrite: overwrite) != nil {
            onSaved()
            dismiss()
        }
    }

    // MARK: Vorschau

    private var previewSection: some View {
        Section {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                if let png = model.previewPNG, let image = UIImage(data: png) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                        .opacity(model.isPreviewBlockedByLength ? 0.35 : 1)
                    if model.isPreviewBlockedByLength {
                        PreviewBlockedLabel()
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                } else if model.isPreviewBlockedByLength {
                    PreviewBlockedLabel()
                } else if model.previewError == nil {
                    ProgressView()
                } else {
                    Image(systemName: "eye.slash").foregroundStyle(.tertiary)
                }
                if model.isRenderingPreview && model.previewPNG != nil && !model.isPreviewBlockedByLength {
                    ProgressView().padding(8).background(.regularMaterial, in: Circle())
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if let reason = model.draft.incompleteReason, model.isPreviewBlockedByLength {
                Text(reason).font(.caption).foregroundStyle(.red)
            } else if let error = model.previewError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if let reason = model.draft.incompleteReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Vorschau")
        }
    }

    // MARK: Typ

    private var kindSection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(model.availableKinds) { kind in
                    let selected = model.draft.kind == kind
                    Button(kind.label) { model.draft.kind = kind }
                        .buttonStyle(.bordered)
                        .tint(selected ? .accentColor : .secondary)
                        .fontWeight(selected ? .semibold : .regular)
                        .disabled(!model.isKindEnabled(kind) && !selected)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text("Inhalt")
        } footer: {
            if model.isActiveSlot {
                Text("Die gerade angezeigte Ansicht kann nicht deaktiviert werden.")
            }
        }
    }

    // MARK: Text

    private var textSections: some View {
        @Bindable var model = model
        return TextContentFields(text: $model.draft.text)
    }

    // MARK: Bild

    @ViewBuilder
    private var imageSections: some View {
        @Bindable var model = model
        // Die Label-Closure von PhotosPicker ist @Sendable – Wert vorher auf dem MainActor lesen.
        let pickerTitle = model.draft.image.mediaId == nil ? "Foto auswählen" : "Anderes Foto auswählen"
        Section {
            if model.canUploadImage {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(pickerTitle, systemImage: "photo.on.rectangle")
                }
                if CameraPicker.isAvailable {
                    Button { showCamera = true } label: { Label("Foto aufnehmen", systemImage: "camera") }
                }
            }
            if model.canUseMediaLibrary {
                Button { showLibrary = true } label: { Label("Aus Bibliothek", systemImage: "photo.stack") }
            }
            if model.isUploading {
                HStack { ProgressView(); Text("Wird hochgeladen …").foregroundStyle(.secondary) }
            }
            if let error = model.uploadError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Bild")
        }
        .disabled(model.isUploading)

        Section("Darstellung") {
            Picker("Einpassen", selection: $model.draft.image.fit) {
                Text("Zuschneiden").tag(Components.Schemas.ImageContent.FitPayload.crop)
                Text("Füllen").tag(Components.Schemas.ImageContent.FitPayload.fill)
            }
            ColorChoice(title: "Hintergrund", selection: $model.draft.image.background)
            Toggle("Dithering", isOn: $model.draft.image.dither)
        }
    }

    // MARK: Kalender

    @ViewBuilder
    private var calendarSections: some View {
        @Bindable var model = model
        Section {
            TextField("Name", text: $model.draft.calendar.name)
            TextField("https://… oder webcal://…", text: $model.draft.calendar.url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: model.draft.calendar.url) { model.calendarURLChanged() }
            TextField("Zeitzone", text: Binding(
                get: { model.draft.calendar.timezone ?? "" },
                set: { model.draft.calendar.timezone = $0.isEmpty ? nil : $0 }
            ), prompt: Text(model.display?.timezone ?? "Europe/Berlin"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
            Text("Kalender (iCal)")
        }
        Section {
            Button("Prüfen") { Task { await model.checkCalendar() } }
                .disabled(model.calendarCheck == .running || model.draft.calendar.url.isEmpty)
            switch model.calendarCheck {
            case .idle:
                EmptyView()
            case .running:
                HStack { ProgressView(); Text("Kalender wird abgerufen …").foregroundStyle(.secondary) }
            case .ok(let count):
                Label(count.map { "Kalender erreichbar, \($0) Termine gefunden." } ?? "Kalender erreichbar.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    private var deactivatedSection: some View {
        Section {
            Text("Diese Ansicht wird auf dem Display nicht angeboten.").foregroundStyle(.secondary)
        }
    }

    private var readOnlySection: some View {
        Section {
            if case .calendar(let calendar)? = model.original?.content, calendar.source == .zeitwart {
                LabeledContent("Raum", value: calendar.name ?? "–")
                Text("Wird in Zeitwart konfiguriert.").foregroundStyle(.secondary)
            } else {
                Text("Diese Ansicht kann in der App nicht bearbeitet werden.").foregroundStyle(.secondary)
            }
        }
    }
}

/// Platzhalter bzw. Overlay, solange ein Textfeld zu lang ist.
private struct PreviewBlockedLabel: View {
    var body: some View {
        Label(SlotEditorModel.previewAfterShorteningHint, systemImage: "scissors")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
