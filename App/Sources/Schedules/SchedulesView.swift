import DoorZignAPI
import DoorZignCore
import SwiftUI

/// Zeitpläne eines Displays (ui-spec §6): Liste mit Aktiv-Schalter; Anlegen, Bearbeiten, Löschen bei Stufe edit.
struct SchedulesView: View {
    let context: SignedInContext
    let display: Display?
    let onChanged: () -> Void
    @State private var model: SchedulesModel
    @State private var editing: EditTarget?
    @State private var pendingDelete: Schedule?
    @State private var actionError: APIError?

    /// Sheet-Ziel: neuer Zeitplan oder bestehender.
    enum EditTarget: Identifiable {
        case new
        case existing(Schedule)
        var id: String {
            switch self {
            case .new: "neu"
            case .existing(let schedule): schedule.id
            }
        }
        var schedule: Schedule? {
            if case .existing(let schedule) = self { return schedule }
            return nil
        }
    }

    init(context: SignedInContext, displayId: String, display: Display?, onChanged: @escaping () -> Void) {
        self.context = context
        self.display = display
        self.onChanged = onChanged
        _model = State(initialValue: SchedulesModel(displayId: displayId, client: context.client))
    }

    private var canEdit: Bool { display?.allows(.edit) ?? false }

    var body: some View {
        List {
            if let error = model.error, model.schedules.isEmpty {
                ErrorSection(message: error.message)
            }
            if model.hasLoaded && model.schedules.isEmpty && model.error == nil {
                ContentUnavailableView {
                    Label("Keine Zeitpläne", systemImage: "calendar.badge.clock")
                } description: {
                    Text(canEdit
                         ? "Mit einem Zeitplan wird zu festen Zeiten automatisch eine Ansicht angezeigt."
                         : "Für dieses Display sind keine Zeitpläne eingerichtet.")
                }
                .listRowBackground(Color.clear)
            }
            if !model.schedules.isEmpty {
                Section {
                    ForEach(model.schedules, id: \.id) { schedule in
                        row(schedule)
                    }
                } footer: {
                    footer
                }
            }
        }
        .overlay { if !model.hasLoaded && model.error == nil { ProgressView() } }
        .navigationTitle("Zeitpläne")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Label("Zeitplan hinzufügen", systemImage: "plus") }
                }
            }
        }
        .task { if !model.hasLoaded { await model.load() } }
        .refreshable { await model.load() }
        .sheet(item: $editing) { target in
            NavigationStack {
                ScheduleEditView(model: model, display: display, existing: target.schedule) {
                    onChanged()
                }
            }
        }
        .confirmationDialog(
            "Zeitplan löschen?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { schedule in
            Button("Löschen", role: .destructive) {
                Task {
                    if let error = await model.delete(schedule) { actionError = error } else { onChanged() }
                }
            }
        } message: { schedule in
            Text("„\(title(schedule))“ wird entfernt.")
        }
        .alert("Aktion fehlgeschlagen", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError?.message ?? "")
        }
    }

    private func title(_ schedule: Schedule) -> String {
        schedule.name.isEmpty ? String(localized: "Ansicht \(schedule.slot)") : schedule.name
    }

    @ViewBuilder
    private func row(_ schedule: Schedule) -> some View {
        let content = HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(schedule)).font(.body)
                Text("Ansicht \(schedule.slot) · Priorität \(schedule.priority)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("\(ScheduleFormatting.weekdays(schedule.weekdays)) · \(ScheduleFormatting.timeRange(start: schedule.start, end: schedule.end))")
                    if let end = ClockTime(schedule.end), let start = ClockTime(schedule.start), end < start {
                        Image(systemName: "moon.stars").accessibilityLabel("über Mitternacht")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let validity = ScheduleFormatting.validity(from: schedule.validFrom, until: schedule.validUntil) {
                    Text(validity).font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(schedule.enabled ? 1 : 0.55)
            Spacer()
            if model.togglingIds.contains(schedule.id) {
                ProgressView()
            } else {
                Toggle("Aktiviert", isOn: Binding(
                    get: { schedule.enabled },
                    set: { newValue in
                        Task {
                            if let error = await model.setEnabled(newValue, for: schedule) { actionError = error } else { onChanged() }
                        }
                    }
                ))
                .labelsHidden()
                .disabled(!canEdit)
            }
        }
        if canEdit {
            Button { editing = .existing(schedule) } label: { content }
                .tint(.primary)
                .swipeActions {
                    Button("Löschen", role: .destructive) { pendingDelete = schedule }
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bei Überschneidungen gilt der Zeitplan mit der höheren Priorität. Endet ein Zeitraum vor seinem Beginn, läuft er über Mitternacht.")
            if let zoneId = display?.timezone, let zone = TimeZone(identifier: zoneId),
               zone.identifier != TimeZone.current.identifier {
                Text("Alle Zeiten gelten in der Zeitzone des Displays (\(zone.identifier)).")
            }
        }
    }
}
