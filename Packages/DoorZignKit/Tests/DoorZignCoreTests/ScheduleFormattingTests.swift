import Testing
@testable import DoorZignCore

@Suite struct ScheduleFormattingTests {
    @Test func wochentage() {
        #expect(ScheduleFormatting.weekdays([1, 2, 3, 4, 5]) == "Mo–Fr")
        #expect(ScheduleFormatting.weekdays([5, 1, 3]) == "Mo, Mi, Fr")
        #expect(ScheduleFormatting.weekdays([1, 2, 6, 7]) == "Mo, Di, Sa, So")
        #expect(ScheduleFormatting.weekdays([1, 2, 3, 5, 6, 7]) == "Mo–Mi, Fr–So")
        #expect(ScheduleFormatting.weekdays(Array(1...7)) == "Täglich")
        #expect(ScheduleFormatting.weekdays([]) == "–")
    }

    @Test func volleWochentagsnamen() throws {
        try CoreL10n.$bundleOverride.withValue(try #require(CoreL10n.bundle(language: "de"))) {
            #expect(ScheduleFormatting.fullName(1) == "Montag")
            #expect(ScheduleFormatting.fullName(7) == "Sonntag")
        }
        try CoreL10n.$bundleOverride.withValue(try #require(CoreL10n.bundle(language: "en"))) {
            #expect(ScheduleFormatting.fullName(1) == "Monday")
            #expect(ScheduleFormatting.fullName(6) == "Saturday")
        }
    }

    @Test func zeitfenster() throws {
        // Uhrzeiten aus der Locale: feste deutsche Locale für reproduzierbare Werte.
        try CoreL10n.$bundleOverride.withValue(try #require(CoreL10n.bundle(language: "de"))) {
            // Stundenformat (8:00 bzw. 08:00) kommt aus den CLDR-Daten des Systems.
            let day = ClockTime(hour: 8, minute: 0).displayText, night = ClockTime(hour: 6, minute: 0).displayText
            #expect(day.hasSuffix("8:00") && night.hasSuffix("6:00"))
            #expect(ScheduleFormatting.timeRange(start: "08:00", end: "12:00") == "\(day)–12:00 Uhr")
            #expect(ScheduleFormatting.timeRange(start: "22:00", end: "06:00") == "22:00–\(night) Uhr (über Mitternacht)")
        }
    }
}

import Foundation
import HTTPTypes

@Suite struct ScheduleDraftTests {
    @Test func validierung() {
        var draft = ScheduleDraft()
        #expect(draft.isValid)
        draft.weekdays = []
        draft.end = draft.start
        draft.priority = 101
        #expect(draft.problems.count == 3)
        draft = ScheduleDraft()
        draft.validFrom = CalendarDay("2026-12-01")
        draft.validUntil = CalendarDay("2026-11-30")
        #expect(draft.problems == ["„Gültig bis“ liegt vor „Gültig ab“."])
    }

    @Test func mitternachtUndEingabe() throws {
        var draft = ScheduleDraft()
        draft.start = try #require(ClockTime("22:00"))
        draft.end = try #require(ClockTime("06:30"))
        draft.weekdays = [5, 1, 3]
        draft.name = "  Nacht "
        #expect(draft.crossesMidnight && draft.isValid)
        let input = draft.input
        #expect(input.start == "22:00" && input.end == "06:30")
        #expect(input.weekdays == [1, 3, 5])
        #expect(input.name == "Nacht")
        #expect(input.validFrom == nil)
    }

    @Test func uhrzeitUndDatum() {
        #expect(ClockTime("7:05")?.text == "07:05")
        #expect(ClockTime("24:00") == nil)
        let cal = Calendar(identifier: .gregorian)
        let t = ClockTime(hour: 13, minute: 45)
        #expect(ClockTime(date: t.date(in: cal), calendar: cal) == t)
        let d = CalendarDay(year: 2026, month: 3, day: 29)  // Umstellung auf Sommerzeit
        #expect(CalendarDay(date: d.date(in: cal), calendar: cal) == d)
        #expect(ScheduleFormatting.validity(from: "2026-12-01", until: nil) == "ab 01.12.2026")
        #expect(ScheduleFormatting.validity(from: nil, until: nil) == nil)
    }
}

@Suite @MainActor struct SchedulesModelTests {
    nonisolated static func scheduleJSON(id: String, priority: Int, enabled: Bool = true, etag: String = "\"s1\"") -> [String: Any] {
        ["id": id, "displayId": "d-1", "name": "Z\(id)", "slot": 2, "weekdays": [1, 2, 3, 4, 5],
         "start": "08:00", "end": "12:00", "priority": priority, "enabled": enabled, "etag": etag]
    }

    @Test func ladenSortierenUmschaltenKonflikt() async throws {
        let transport = RoutingStubTransport()
        transport.on("listSchedules") { _, _ in
            RoutingStubTransport.json(.ok, ["data": [SchedulesModelTests.scheduleJSON(id: "a", priority: 10), SchedulesModelTests.scheduleJSON(id: "b", priority: 90)]])
        }
        transport.on("updateSchedule") { request, body in
            if request.headerFields[.ifMatch] != "\"s1\"" {
                return RoutingStubTransport.json(.preconditionFailed, ["error": ["code": "conflict", "message": "Geändert"]])
            }
            var json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            json["id"] = "b"; json["displayId"] = "d-1"; json["etag"] = "\"s2\""
            return RoutingStubTransport.json(.ok, json)
        }
        transport.on("createSchedule") { _, body in
            var json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            json["id"] = "c"; json["displayId"] = "d-1"; json["etag"] = "\"c1\""
            return RoutingStubTransport.json(.created, json)
        }
        transport.on("deleteSchedule") { _, _ in (HTTPResponse(status: .noContent), nil) }

        let model = SchedulesModel(displayId: "d-1", client: transport.makeClient())
        await model.load()
        #expect(model.schedules.map(\.id) == ["b", "a"])  // höhere Priorität zuerst

        let b = model.schedules[0]
        #expect(await model.setEnabled(false, for: b) == nil)
        #expect(model.schedules.first { $0.id == "b" }?.enabled == false)
        #expect(transport.requests("updateSchedule").last?.request.headerFields[.ifMatch] == "\"s1\"")

        // Veraltetes ETag → 412 → Konflikt.
        let stale = try #require(model.schedules.first { $0.id == "b" })  // etag jetzt "s2"
        #expect(await model.save(ScheduleDraft(stale), existing: stale) == .conflict)

        var draft = ScheduleDraft()
        draft.priority = 50
        guard case .saved(let created) = await model.save(draft, existing: nil) else { Issue.record("nicht angelegt"); return }
        #expect(created.id == "c")
        #expect(model.schedules.count == 3)

        #expect(await model.delete(created) == nil)
        #expect(model.schedules.count == 2)
    }
}
