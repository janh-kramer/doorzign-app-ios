import DoorZignAPI
import Foundation
import Observation
import OpenAPIRuntime

public typealias Adhoc = Components.Schemas.Adhoc
public typealias Schedule = Components.Schemas.Schedule
public typealias CalendarStatus = Components.Schemas.CalendarStatus

/// Zustand des Display-Details: Display, drei Ansichten, Ad-hoc, Zeitpläne, Kalender und Aufträge.
@MainActor
@Observable
public final class DisplayDetailModel {
    public let displayId: String
    public private(set) var display: Display?
    public private(set) var slots: [Slot] = []
    public private(set) var adhoc: Adhoc?
    public private(set) var schedules: [Schedule] = []
    public private(set) var calendar: CalendarStatus?
    public private(set) var jobs: [Job] = []

    public private(set) var isLoading = false
    /// Ladefehler (Display nicht mehr sichtbar → `not_found`).
    public private(set) var error: APIError?
    /// Laufende Aktion (für Fortschrittsanzeige und Sperre).
    public private(set) var runningAction: Action?

    public enum Action: Equatable, Sendable {
        case switchSlot(Int)
        case identify
        case resend
        case endAdhoc
    }

    @ObservationIgnored private let client: Client
    @ObservationIgnored private let system: SystemInfo?
    @ObservationIgnored private var fastPollingSince: Date?

    public init(displayId: String, initial: Display? = nil, client: Client, system: SystemInfo?) {
        self.displayId = displayId
        self.display = initial
        self.client = client
        self.system = system
    }

    // MARK: Rechte und Funktionen

    /// Fehlt `System` (noch nicht geladen), werden optionale Funktionen ausgeblendet.
    private func has(_ feature: Feature) -> Bool { system?.has(feature) ?? false }

    public var canSwitch: Bool { display?.allows(._switch) ?? false }
    public var canEdit: Bool { display?.allows(.edit) ?? false }
    public var canIdentify: Bool { canSwitch && has(.identify) }
    public var showsAdhoc: Bool { has(.adhoc) }
    public var showsSchedules: Bool { has(.schedules) }
    public var showsCalendar: Bool { slots.contains { $0.content.isCalendar } }

    public var hasOpenJobs: Bool { jobs.contains { $0.isActive() } || slots.contains { $0.transfer?.status.isOpen == true } }

    public func canActivate(_ slot: Slot) -> Bool {
        canSwitch && slot.slot != display?.activeSlot && !slot.content.isDeactivated
    }

    // MARK: Laden

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let displayResult = expect(try await client.getDisplay(path: .init(displayId: displayId))) { try $0.ok.body.json }
            async let slotsResult = expect(try await client.listSlots(path: .init(displayId: displayId))) { try $0.ok.body.json.data }
            async let jobsResult = expect(try await client.listDisplayJobs(path: .init(displayId: displayId))) { try $0.ok.body.json.data }
            let (display, slots, jobs) = try await (displayResult, slotsResult, jobsResult)
            self.display = display
            self.slots = slots.sorted { $0.slot < $1.slot }
            self.jobs = jobs.sorted { $0.createdAt > $1.createdAt }
            error = nil
        } catch {
            let apiError = APIError.from(error)
            if apiError.code != "cancelled" { self.error = apiError }
            return
        }
        // Optionale Abschnitte: Fehler dort sollen das Detail nicht blockieren.
        async let adhoc: Void = loadAdhoc()
        async let schedules: Void = loadSchedules()
        async let calendar: Void = loadCalendar()
        _ = await (adhoc, schedules, calendar)
        updatePollingState()
    }

    private func loadAdhoc() async {
        guard showsAdhoc else { adhoc = nil; return }
        guard let output = try? await client.getAdhoc(path: .init(displayId: displayId)) else { return }
        switch output {
        case .ok(let ok): adhoc = try? ok.body.json
        case .noContent: adhoc = nil
        default: break
        }
    }

    private func loadSchedules() async {
        guard showsSchedules else { schedules = []; return }
        if let list = try? await client.listSchedules(path: .init(displayId: displayId)).ok.body.json.data {
            schedules = SchedulesModel.sorted(list)
        }
    }

    /// Nach Änderungen im Zeitplan-Screen: Zusammenfassung im Detail aktualisieren.
    public func reloadSchedules() async {
        await loadSchedules()
    }

    private func loadCalendar() async {
        guard let calendarSlot = slots.first(where: { $0.content.isCalendar }) else { calendar = nil; return }
        if let status = try? await client.getCalendarStatus(
            path: .init(displayId: displayId),
            query: .init(slot: calendarSlot.slot)
        ).ok.body.json {
            calendar = status
        }
    }

    /// Nur Display und Aufträge (für das schnelle Polling).
    public func refreshTransfers() async {
        async let displayResult = try? client.getDisplay(path: .init(displayId: displayId)).ok.body.json
        async let slotsResult = try? client.listSlots(path: .init(displayId: displayId)).ok.body.json.data
        async let jobsResult = try? client.listDisplayJobs(path: .init(displayId: displayId)).ok.body.json.data
        let (display, slots, jobs) = await (displayResult, slotsResult, jobsResult)
        if let display { self.display = display }
        if let slots { self.slots = slots.sorted { $0.slot < $1.slot } }
        if let jobs { self.jobs = jobs.sorted { $0.createdAt > $1.createdAt } }
        updatePollingState()
    }

    private func updatePollingState(now: Date = Date()) {
        if hasOpenJobs {
            if fastPollingSince == nil { fastPollingSince = now }
        } else {
            fastPollingSince = nil
        }
    }

    /// Lädt sofort und aktualisiert dann nach der Polling-Regel, bis die Task abgebrochen wird.
    public func autoRefresh() async {
        await load()
        while !Task.isCancelled {
            let interval = JobPolling.interval(hasOpenJobs: hasOpenJobs, fastSince: fastPollingSince)
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            if interval == JobPolling.fast {
                await refreshTransfers()
            } else {
                await load()
            }
        }
    }

    /// Nach dem Speichern einer Ansicht im Editor: Übertragung sofort beobachten.
    public func contentSaved() async {
        fastPollingSince = Date()
        await refreshTransfers()
        await loadAdhoc()
    }

    // MARK: Aktionen

    /// Aktive Ansicht umschalten (Stufe switch).
    public func activate(slot: Int) async throws {
        try await perform(.switchSlot(slot)) {
            _ = try expect(try await self.client.setActiveSlot(
                path: .init(displayId: self.displayId),
                body: .json(.init(slot: slot))
            )) { try $0.accepted.body.json }
        }
    }

    /// LED blinken lassen (Stufe switch, Feature `identify`).
    public func identify() async throws {
        try await perform(.identify) {
            _ = try expect(try await self.client.identifyDisplay(path: .init(displayId: self.displayId))) {
                try $0.accepted.body.json
            }
        }
    }

    /// Alle Ansichten erneut übertragen (Stufe edit). Liefert die Zahl der angelegten Aufträge –
    /// je nach Backend 0 bis 3 (Zeitwart überträgt nur die aktive Ansicht).
    @discardableResult
    public func resend() async throws -> Int {
        var count = 0
        try await perform(.resend) {
            count = try expect(try await self.client.resendDisplay(path: .init(displayId: self.displayId))) {
                try $0.accepted.body.json.data.count
            }
        }
        return count
    }

    /// Laufende Ad-hoc-Nachricht beenden (Stufe edit).
    public func endAdhoc() async throws {
        try await perform(.endAdhoc) {
            _ = try expect(try await self.client.endAdhoc(path: .init(displayId: self.displayId))) {
                try $0.noContent
            }
            self.adhoc = nil
        }
    }

    private func perform(_ action: Action, _ body: () async throws -> Void) async throws {
        guard runningAction == nil else { return }
        runningAction = action
        defer { runningAction = nil }
        do {
            try await body()
        } catch {
            throw APIError.from(error)
        }
        // Neuer Auftrag: sofort schnell pollen.
        fastPollingSince = Date()
        await refreshTransfers()
    }
}
