import DoorZignAPI
import DoorZignCore
import SwiftUI

/// Display-Detail (ui-spec §3): Kopf, drei Ansichten, Aktionen, Ad-hoc, Zeitpläne, Kalender, Aufträge.
struct DisplayDetailView: View {
    let context: SignedInContext
    @State private var model: DisplayDetailModel
    @State private var actionError: APIError?
    @State private var confirmResend = false
    @State private var confirmEndAdhoc = false
    @State private var notice: String?
    /// Aus dem Menü einer Ansicht geöffneter Editor (Menüeinträge können keinen NavigationLink tragen).
    @State private var editorRoute: SlotEditorRoute?

    init(context: SignedInContext, displayId: String, initial: Display?) {
        self.context = context
        _model = State(initialValue: DisplayDetailModel(
            displayId: displayId,
            initial: initial,
            client: context.client,
            system: context.system
        ))
    }

    var body: some View {
        Group {
            if let display = model.display {
                content(display)
            } else if let error = model.error {
                ContentUnavailableView("Nicht verfügbar", systemImage: "rectangle.portrait.slash",
                                       description: Text(error.message))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.display?.name ?? "Display")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .task { await model.autoRefresh() }
        .navigationDestination(for: AdhocRoute.self) { route in
            AdhocView(context: context, displayId: route.displayId) {
                Task { await model.contentSaved() }
            }
        }
        .navigationDestination(item: $editorRoute) { route in
            SlotEditorView(context: context, displayId: route.displayId, slot: route.slot, display: model.display) {
                Task { await model.contentSaved() }
            }
        }
        .navigationDestination(for: JobsRoute.self) { route in
            JobsView(context: context, scope: .display(route.displayId), title: model.display?.name)
        }
        .navigationDestination(for: SchedulesRoute.self) { route in
            SchedulesView(context: context, displayId: route.displayId, display: model.display) {
                Task { await model.reloadSchedules() }
            }
        }
        .refreshable { await model.load() }
        .alert("Aktion fehlgeschlagen", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError?.message ?? "")
        }
        .confirmationDialog("Alle Ansichten erneut übertragen?", isPresented: $confirmResend, titleVisibility: .visible) {
            Button("Erneut übertragen") {
                Task {
                    do {
                        let count = try await model.resend()
                        withAnimation {
                            notice = count == 0 ? String(localized: "Es gibt nichts erneut zu übertragen.") : String(localized: "Wird erneut übertragen.")
                        }
                    } catch {
                        actionError = APIError.from(error)
                    }
                }
            }
        }
        .confirmationDialog("Ad-hoc-Nachricht beenden?", isPresented: $confirmEndAdhoc, titleVisibility: .visible) {
            Button("Beenden", role: .destructive) { run { try await model.endAdhoc() } }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .floatingGlass(in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { self.notice = nil }
                    }
            }
        }
    }

    // MARK: Inhalt

    private func content(_ display: Display) -> some View {
        List {
            Section { DisplayHeader(display: display) }

            if let error = model.error {
                Section {
                    Label(error.message, systemImage: "wifi.exclamationmark")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Ansichten") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(model.slots, id: \.slot) { slot in
                            slotCard(slot, display: display)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if model.canIdentify {
                    Button {
                        run { try await model.identify() } success: { String(localized: "Das Display blinkt gleich.") }
                    } label: {
                        Label("Display finden", systemImage: "light.beacon.max")
                    }
                    .disabled(model.runningAction != nil)
                }
            }

            if model.showsAdhoc { adhocSection(display) }
            if model.showsSchedules { schedulesSection(display) }
            if model.showsCalendar, let calendar = model.calendar { CalendarSection(status: calendar) }
            jobsSection
        }
    }

    /// Vorschaukarte einer Ansicht. Tippen öffnet ein Menü: zuerst „anzeigen“, darunter abgesetzt „bearbeiten“.
    /// Ohne erlaubte Aktion (z. B. aktive Ansicht für Nur-Lesen-Benutzer) bleibt die Karte ein reines Bild.
    @ViewBuilder
    private func slotCard(_ slot: Slot, display: Display) -> some View {
        let card = SlotCard(
            slot: slot,
            isActive: slot.slot == display.activeSlot,
            display: display,
            previews: context.previews
        )
        let canShow = model.canActivate(slot)
        let canEditSlot = model.canEdit && slot.editable
        if canShow || canEditSlot {
            Menu {
                if canShow {
                    Section {
                        Button("Ansicht \(slot.slot) anzeigen", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                            run { try await model.activate(slot: slot.slot) } success: { String(localized: "Ansicht \(slot.slot) wird angezeigt.") }
                        }
                        .disabled(model.runningAction != nil)
                    }
                }
                if canEditSlot {
                    Section {
                        Button("Ansicht \(slot.slot) bearbeiten", systemImage: "pencil") {
                            editorRoute = SlotEditorRoute(displayId: display.id, slot: slot.slot)
                        }
                    }
                }
            } label: {
                card.contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        } else {
            card
        }
    }

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        if model.canEdit {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Erneut übertragen", systemImage: "arrow.clockwise.icloud") { confirmResend = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Weitere Aktionen")
            }
        }
    }

    // MARK: Ad-hoc

    @ViewBuilder
    private func adhocSection(_ display: Display) -> some View {
        Section("Ad-hoc-Nachricht") {
            if let adhoc = model.adhoc, adhoc.endsAt > Date() {
                VStack(alignment: .leading, spacing: 4) {
                    if let headline = adhoc.content.headline, !headline.isEmpty {
                        Text(headline).font(.headline)
                    }
                    if let message = adhoc.content.message, !message.isEmpty {
                        Text(message)
                    }
                    HStack(spacing: 4) {
                        Text("Noch")
                        Text(timerInterval: Date()...adhoc.endsAt, countsDown: true)
                            .monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if model.canEdit {
                    Button("Beenden", role: .destructive) { confirmEndAdhoc = true }
                        .disabled(model.runningAction != nil)
                }
            } else {
                Text("Keine Nachricht aktiv").foregroundStyle(.secondary)
            }
            if model.canEdit {
                NavigationLink(value: AdhocRoute(displayId: display.id)) {
                    Label(model.adhoc == nil ? "Nachricht anzeigen" : "Nachricht ersetzen", systemImage: "text.bubble")
                }
            }
        }
    }

    // MARK: Zeitpläne

    private func schedulesSection(_ display: Display) -> some View {
        Section {
            if model.schedules.isEmpty {
                Text("Keine Zeitpläne").foregroundStyle(.secondary)
            }
            ForEach(model.schedules.prefix(3), id: \.id) { schedule in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(schedule.name.isEmpty ? String(localized: "Ansicht \(schedule.slot)") : schedule.name)
                        if !schedule.enabled {
                            Text("Aus").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("\(ScheduleFormatting.weekdays(schedule.weekdays)) · \(ScheduleFormatting.timeRange(start: schedule.start, end: schedule.end))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .opacity(schedule.enabled ? 1 : 0.6)
            }
            NavigationLink(value: SchedulesRoute(displayId: display.id)) {
                Text(model.schedules.count > 3 ? "Alle \(model.schedules.count) Zeitpläne" : "Zeitpläne verwalten")
            }
        } header: {
            Text("Zeitpläne")
        } footer: {
            if let zone = TimeZone(identifier: display.timezone), zone.identifier != TimeZone.current.identifier {
                Text("Zeiten gelten in der Zeitzone \(zone.identifier).")
            }
        }
    }

    // MARK: Aufträge

    private var jobsSection: some View {
        Section("Aufträge") {
            if model.jobs.isEmpty {
                Text("Keine Aufträge").foregroundStyle(.secondary)
            }
            ForEach(model.jobs.prefix(5), id: \.id) { job in
                JobRow(job: job)
            }
            if !model.jobs.isEmpty {
                NavigationLink(value: JobsRoute(displayId: model.displayId)) {
                    Text(model.jobs.count > 5 ? "Alle \(model.jobs.count) Aufträge" : "Aufträge anzeigen")
                }
            }
        }
    }

    // MARK: Hilfen

    /// Führt eine Aktion aus; Fehler als Alert, Erfolg optional als kurzer Hinweis.
    private func run(_ action: @escaping () async throws -> Void, success: (() -> String)? = nil) {
        Task {
            do {
                try await action()
                if let success { withAnimation { notice = success() } }
            } catch {
                actionError = APIError.from(error)
            }
        }
    }
}

// MARK: - Navigationsziele

struct SlotEditorRoute: Hashable { let displayId: String; let slot: Int }
struct AdhocRoute: Hashable { let displayId: String }
struct SchedulesRoute: Hashable { let displayId: String }
struct JobsRoute: Hashable { let displayId: String }

// MARK: - Bausteine

/// Kopf: Name, Ort, Modell, Online/zuletzt gesehen, Akku, Signal, Lizenz.
struct DisplayHeader: View {
    let display: Display

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(display.name).font(.title3.bold())
                Spacer()
                OnlineChip(online: display.online)
            }
            if let location = display.location, !location.isEmpty {
                Text(location).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                BatteryIndicator(percent: display.battery)
                SignalIndicator(rssi: display.signal)
            }
            .font(.subheadline)
            Group {
                if !display.online, let lastSeen = display.lastSeen {
                    Text("Zuletzt gesehen \(lastSeen, format: .relative(presentation: .named))")
                }
                Text([display.model, display.firmware.map { "Firmware \($0)" }].compactMap { $0 }.joined(separator: " · "))
                Text(Self.licenseText(display.license))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error = display.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    static func licenseText(_ license: Display.LicensePayload) -> String {
        let name: String = switch license._type {
        case "doorzign": String(localized: "DoorZign-Lizenz")
        case "ical_connect": String(localized: "iCal-Connect-Lizenz")
        case "none": String(localized: "Keine Lizenz")
        default: String(localized: "Lizenz")
        }
        guard let validUntil = license.validUntil, license._type != "none" else { return name }
        return String(localized: "\(name), gültig bis \(Self.formatDate(validUntil))")
    }

    /// `YYYY-MM-DD` → „31.12.2026“ (Format nach Gerätesprache).
    static func formatDate(_ value: String) -> String {
        CalendarDay(value)?.displayText ?? value
    }
}

/// Karte einer Ansicht: Vorschau, Typ, aktiv, Übertragungsstatus.
struct SlotCard: View {
    let slot: Slot
    let isActive: Bool
    let display: Display
    let previews: PreviewLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PreviewThumbnail(previews: previews, displayId: display.id, slot: slot.slot,
                             etag: slot.previewEtag, refreshKey: slot.etag)
                .frame(width: 150, height: 112)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isActive ? Color.accentColor : .clear, lineWidth: 3)
                )
            HStack(spacing: 4) {
                Text("Ansicht \(slot.slot)").font(.subheadline.weight(.semibold))
                if isActive {
                    Text("Aktiv")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text(slot.content.typeLabel).font(.caption).foregroundStyle(.secondary)
            let status = slot.transferStatus(isActive: isActive)
            HStack(spacing: 4) {
                if status.tone == .busy {
                    ProgressView().controlSize(.mini)
                }
                Text(status.label)
            }
            .font(.caption2)
            .foregroundStyle(Self.color(for: status.tone))
        }
        .frame(width: 150)
        .accessibilityElement(children: .combine)
    }

    static func color(for tone: Slot.TransferTone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .busy: .blue
        case .warning: .orange
        case .failure: .red
        }
    }
}

struct CalendarSection: View {
    let status: CalendarStatus

    var body: some View {
        Section {
            if !status.licensed {
                Label("Keine Kalenderlizenz", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if !status.configured {
                Text("Kein Kalender eingerichtet").foregroundStyle(.secondary)
            } else {
                if let occupied = status.occupied {
                    Label(occupied ? "Belegt" : "Frei", systemImage: occupied ? "circle.fill" : "circle")
                        .foregroundStyle(occupied ? Color.red : Color.green)
                }
                if let error = status.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
                ForEach(Array((status.eventsToday ?? []).enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading) {
                        Text(event.title)
                        Text(event.allDay == true
                             ? String(localized: "Ganztägig")
                             : "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let last = status.lastSuccessAt {
                    Text("Zuletzt abgerufen \(last, format: .relative(presentation: .named))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(status.source == .zeitwart ? "Raumanzeige" : "Kalender")
        } footer: {
            if status.source == .zeitwart {
                Text("Wird in Zeitwart konfiguriert.")
            }
        }
    }
}
