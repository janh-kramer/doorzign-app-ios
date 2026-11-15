import DoorZignAPI
import DoorZignCore
import SwiftUI

/// Zeitplan anlegen oder bearbeiten (ui-spec §6). Speichert mit If-Match; bei 412 Konfliktdialog.
struct ScheduleEditView: View {
    let model: SchedulesModel
    let display: Display?
    let existing: Schedule?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduleDraft
    @State private var original: ScheduleDraft
    @State private var isSaving = false
    @State private var saveError: APIError?
    @State private var hasConflict = false
    @State private var confirmDiscard = false

    init(model: SchedulesModel, display: Display?, existing: Schedule?, onSaved: @escaping () -> Void) {
        self.model = model
        self.display = display
        self.existing = existing
        self.onSaved = onSaved
        let initial = existing.map(ScheduleDraft.init) ?? ScheduleDraft()
        _draft = State(initialValue: initial)
        _original = State(initialValue: initial)
    }

    private var isDirty: Bool { draft != original || existing == nil }

    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $draft.name)
                Picker("Ansicht", selection: $draft.slot) {
                    ForEach(1...3, id: \.self) { Text("Ansicht \($0)").tag($0) }
                }
                Toggle("Aktiviert", isOn: $draft.enabled)
            }

            Section {
                WeekdayPicker(selection: $draft.weekdays)
                DatePicker("Beginn", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                DatePicker("Ende", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
            } header: {
                Text("Wann")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if draft.crossesMidnight {
                        Label("Läuft über Mitternacht bis \(draft.end.displayText) am Folgetag.", systemImage: "moon.stars")
                    }
                    if let zoneId = display?.timezone, let zone = TimeZone(identifier: zoneId),
                       zone.identifier != TimeZone.current.identifier {
                        Text("Zeiten gelten in der Zeitzone des Displays (\(zone.identifier)).")
                    }
                }
            }

            Section("Gültigkeit") {
                OptionalDayPicker(title: "Gültig ab", day: $draft.validFrom)
                OptionalDayPicker(title: "Gültig bis", day: $draft.validUntil)
            }

            Section {
                Stepper(value: $draft.priority, in: 0...100) {
                    LabeledContent("Priorität", value: "\(draft.priority)")
                }
            } footer: {
                Text("Bei Überschneidungen gewinnt die höhere Priorität (0–100).")
            }

            if !draft.problems.isEmpty || saveError != nil {
                Section {
                    ForEach(draft.problems, id: \.self) { Text($0).foregroundStyle(.red) }
                    if let saveError {
                        Text(saveError.message).foregroundStyle(.red)
                        ForEach(saveError.fields.sorted(by: { $0.key < $1.key }), id: \.key) { _, messages in
                            ForEach(messages, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
        }
        .navigationTitle(existing == nil ? "Neuer Zeitplan" : "Zeitplan bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(draft != original)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen") {
                    if draft != original { confirmDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Sichern") { Task { await save() } }
                        .disabled(!draft.isValid || !isDirty)
                }
            }
        }
        .confirmationDialog("Änderungen verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) { dismiss() }
        }
        .alert("Inzwischen geändert", isPresented: $hasConflict) {
            Button("Neu laden") {
                Task { await model.load(); dismiss() }
            }
            Button("Überschreiben", role: .destructive) { Task { await save(overwrite: true) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Neu laden verwirft deine Änderungen. Überschreiben ersetzt die Änderungen der anderen Person.")
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<ScheduleDraft, ClockTime>) -> Binding<Date> {
        Binding(
            get: { draft[keyPath: keyPath].date() },
            set: { draft[keyPath: keyPath] = ClockTime(date: $0) }
        )
    }

    private func save(overwrite: Bool = false) async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        switch await model.save(draft, existing: existing, overwrite: overwrite) {
        case .saved:
            onSaved()
            dismiss()
        case .conflict:
            hasConflict = true
        case .failed(let error):
            saveError = error
        }
    }
}

/// Wochentage als Umschaltknöpfe Mo–So (1 = Montag).
private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var rowWidth: CGFloat = 0

    private let spacing: CGFloat = 6
    private let inset: CGFloat = 4

    /// Eine gemeinsame Schriftgröße für alle Kapseln (ui-spec §Zeitpläne): so groß, wie Dynamic Type
    /// vorgibt, höchstens so groß, dass das breiteste Kürzel (fett) in eine Kapsel passt. So werden bei
    /// großer Schrift alle Kürzel gleich verkleinert statt einzeln oder per Umbruch.
    private var fontSize: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let base = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize
        guard rowWidth > 0 else { return base }
        let available = (rowWidth - spacing * 6) / 7 - inset * 2
        let font = UIFont.systemFont(ofSize: base, weight: .semibold)
        let widest = ScheduleFormatting.abbreviations
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        guard widest > available, available > 0 else { return base }
        return max(base * available / widest, 8)
    }

    var body: some View {
        // Sieben gleich breite Kapseln in einer Zeile, Kürzel einzeilig.
        HStack(spacing: spacing) {
            ForEach(1...7, id: \.self) { day in
                let selected = selection.contains(day)
                Button {
                    if selected { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(ScheduleFormatting.abbreviations[day - 1])
                        .font(.system(size: fontSize, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, inset)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ScheduleFormatting.fullName(day))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }
}

/// Optionales Datum: Schalter plus DatePicker.
private struct OptionalDayPicker: View {
    let title: LocalizedStringKey
    @Binding var day: CalendarDay?

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { day != nil },
            set: { day = $0 ? (day ?? CalendarDay(date: Date())) : nil }
        ))
        if let current = day {
            DatePicker(title, selection: Binding(
                get: { current.date() },
                set: { day = CalendarDay(date: $0) }
            ), displayedComponents: .date)
            .labelsHidden()
        }
    }
}
