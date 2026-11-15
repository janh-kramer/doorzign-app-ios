import DoorZignAPI
import Foundation
import HTTPTypes
import Testing
@testable import DoorZignCore

/// Vertrags-Fixture als JSON-Objekt (Inhalt von `value`, falls als OpenAPI-Example abgelegt).
func contractFixture(_ name: String) throws -> Any {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../../../doorzign-app-coordination/contract/fixtures/\(name)")
        .standardizedFileURL
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    if let wrapper = object as? [String: Any], let value = wrapper["value"] { return value }
    return object
}

func fixtureSystem(_ name: String) throws -> SystemInfo {
    let data = try JSONSerialization.data(withJSONObject: try contractFixture(name))
    return SystemInfo(try JSONDecoder().decode(Components.Schemas.System.self, from: data))
}

@Suite @MainActor struct DisplayListModelTests {
    @Test func etagUnd304() async throws {
        let displays = try contractFixture("displays.json")
        let transport = RoutingStubTransport()
        transport.on("listDisplays") { request, _ in
            if request.headerFields[.ifNoneMatch] == "\"l1\"" { return (HTTPResponse(status: .notModified), nil) }
            var (response, body) = RoutingStubTransport.json(.ok, displays)
            response.headerFields[.eTag] = "\"l1\""
            return (response, body)
        }
        let model = DisplayListModel(client: transport.makeClient())
        await model.load()
        let count = model.displays.count
        #expect(count > 0 && model.error == nil)
        #expect(transport.requests("listDisplays").first?.request.headerFields[.ifNoneMatch] == nil)

        await model.load()
        #expect(transport.requests("listDisplays").last?.request.headerFields[.ifNoneMatch] == "\"l1\"")
        #expect(model.displays.count == count)  // 304: unverändert

        // Fehler danach: Liste bleibt, Fehler wird angezeigt.
        transport.on("listDisplays") { _, _ in
            RoutingStubTransport.json(.serviceUnavailable, ["error": ["code": "unavailable", "message": "Verbund wählt Master"]])
        }
        await model.load()
        #expect(model.displays.count == count)
        #expect(model.error?.statusCode == 503)
    }
}

@Suite @MainActor struct DisplayDetailModelTests {
    static func makeTransport(display: String = "display-edit.json") throws -> RoutingStubTransport {
        let displayJSON = try contractFixture(display)
        let slots = try contractFixture("slots.json")
        let jobs = try contractFixture("jobs.json")
        let schedules = try contractFixture("schedules.json")
        let calendar = try contractFixture("calendar-status.json")
        let transport = RoutingStubTransport()
        transport.on("getDisplay") { _, _ in RoutingStubTransport.json(.ok, displayJSON) }
        transport.on("listSlots") { _, _ in RoutingStubTransport.json(.ok, slots) }
        transport.on("listDisplayJobs") { _, _ in RoutingStubTransport.json(.ok, jobs) }
        transport.on("listSchedules") { _, _ in RoutingStubTransport.json(.ok, schedules) }
        transport.on("getCalendarStatus") { _, _ in RoutingStubTransport.json(.ok, calendar) }
        // Ad-hoc schlägt fehl – darf das Detail nicht blockieren.
        transport.on("getAdhoc") { _, _ in
            RoutingStubTransport.json(.internalServerError, ["error": ["code": "internal", "message": "kaputt"]])
        }
        return transport
    }

    @Test func ladenRechteUndOptionaleAbschnitte() async throws {
        let transport = try Self.makeTransport()
        let model = DisplayDetailModel(displayId: "d-1", client: transport.makeClient(), system: try fixtureSystem("system-edge.json"))
        await model.load()
        #expect(model.error == nil)
        #expect(model.slots.map(\.slot) == [1, 2, 3])
        #expect(model.canEdit && model.canSwitch && model.canIdentify)
        #expect(model.showsAdhoc && model.showsSchedules)
        #expect(model.adhoc == nil)                      // Fehler beim Ad-hoc ignoriert
        #expect(!model.schedules.isEmpty)
        #expect((model.calendar != nil) == model.showsCalendar)
        // Zeitpläne nach Priorität sortiert.
        #expect(model.schedules.map(\.priority) == model.schedules.map(\.priority).sorted(by: >))
        // Aufträge neueste zuerst.
        #expect(model.jobs.map(\.createdAt) == model.jobs.map(\.createdAt).sorted(by: >))
    }

    @Test func ohneSystemKeineOptionalenFunktionen() async throws {
        let transport = try Self.makeTransport()
        let model = DisplayDetailModel(displayId: "d-1", client: transport.makeClient(), system: nil)
        await model.load()
        #expect(!model.canIdentify && !model.showsAdhoc && !model.showsSchedules)
        #expect(transport.requests("listSchedules").isEmpty && transport.requests("getAdhoc").isEmpty)
    }

    @Test func stufeView() async throws {
        let transport = try Self.makeTransport(display: "display-view.json")
        let model = DisplayDetailModel(displayId: "d-1", client: transport.makeClient(), system: try fixtureSystem("system-edge.json"))
        await model.load()
        #expect(!model.canSwitch && !model.canEdit && !model.canIdentify)
        #expect(model.slots.allSatisfy { !model.canActivate($0) })
    }

    @Test func aktionen() async throws {
        let transport = try Self.makeTransport()
        let jobs = try contractFixture("jobs.json") as! [String: Any]
        let firstJob = (jobs["data"] as! [[String: Any]])[0]
        transport.on("setActiveSlot") { _, _ in RoutingStubTransport.json(.accepted, firstJob) }
        transport.on("identifyDisplay") { _, _ in RoutingStubTransport.json(.accepted, firstJob) }
        transport.on("resendDisplay") { _, _ in RoutingStubTransport.json(.accepted, ["data": [firstJob, firstJob]]) }
        transport.on("endAdhoc") { _, _ in (HTTPResponse(status: .noContent), nil) }

        let model = DisplayDetailModel(displayId: "d-1", client: transport.makeClient(), system: try fixtureSystem("system-edge.json"))
        await model.load()
        let before = transport.requests("listDisplayJobs").count
        try await model.activate(slot: 2)
        let body = try #require(transport.requests("setActiveSlot").last?.body)
        #expect((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["slot"] as? Int == 2)
        #expect(transport.requests("listDisplayJobs").count == before + 1)  // sofort aktualisiert
        try await model.identify()
        #expect(try await model.resend() == 2)
        try await model.endAdhoc()
        #expect(model.runningAction == nil)

        // Fehler werden als APIError weitergereicht.
        transport.on("identifyDisplay") { _, _ in
            RoutingStubTransport.json(.forbidden, ["error": ["code": "forbidden", "message": "Keine Berechtigung"]])
        }
        await #expect(throws: APIError.self) { try await model.identify() }
    }

    @Test func displayNichtMehrSichtbar() async throws {
        let transport = try Self.makeTransport()
        let notFound = try contractFixture("error-404.json")
        transport.on("getDisplay") { _, _ in RoutingStubTransport.json(.notFound, notFound) }
        let model = DisplayDetailModel(displayId: "d-1", client: transport.makeClient(), system: nil)
        await model.load()
        #expect(model.error?.statusCode == 404)
    }
}
