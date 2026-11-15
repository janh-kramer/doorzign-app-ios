import DoorZignAPI
import Foundation
import HTTPTypes
import Testing
@testable import DoorZignCore

@Suite @MainActor struct JobsModelTests {
    nonisolated static func job(_ id: String, _ status: String, created: String, scheduled: String? = nil,
                                code: String? = nil, message: String? = nil) -> [String: Any] {
        var json: [String: Any] = ["id": id, "displayId": "d-1", "displayName": "Foyer", "type": "upload_image",
                                   "slot": 2, "status": status, "createdAt": created]
        if let scheduled { json["scheduledAt"] = scheduled }
        if let code { json["errorCode"] = code }
        if let message { json["errorMessage"] = message }
        return json
    }

    @Test func abschnitteUndFilter() async throws {
        let transport = RoutingStubTransport()
        transport.on("listDisplayJobs") { _, _ in
            RoutingStubTransport.json(.ok, ["data": [
                JobsModelTests.job("alt", "done", created: "2026-11-15T08:00:00Z"),
                JobsModelTests.job("neu", "progress", created: "2026-11-15T10:00:00Z"),
                JobsModelTests.job("plan", "pending", created: "2026-11-15T09:00:00Z", scheduled: "2099-01-01T00:00:00Z"),
                JobsModelTests.job("kaputt", "failed", created: "2026-11-15T09:30:00Z", code: "not_in_range"),
            ]])
        }
        let model = JobsModel(scope: .display("d-1"), client: transport.makeClient())
        await model.load()
        #expect(model.error == nil)
        #expect(model.jobs.map(\.id) == ["neu", "kaputt", "plan", "alt"])
        #expect(model.hasOpenJobs)
        #expect(model.pollingInterval == JobPolling.fast)

        let sections = model.sections()
        #expect(sections.active.map(\.id) == ["neu"])
        #expect(sections.scheduled.map(\.id) == ["plan"])
        #expect(sections.finished.map(\.id) == ["kaputt", "alt"])

        model.filter = .failed
        #expect(model.sections().finished.map(\.id) == ["kaputt"])
        #expect(model.count(for: .open) == 2)
        #expect(model.jobs.first { $0.id == "kaputt" }?.errorText == "Display außer Reichweite.")
    }

    @Test func globalMitETagUndUnvollstaendig() async throws {
        let transport = RoutingStubTransport()
        transport.on("listJobs") { request, _ in
            if request.headerFields[.ifNoneMatch] == "\"j1\"" { return (HTTPResponse(status: .notModified), nil) }
            var (response, body) = RoutingStubTransport.json(.ok, [
                "data": [JobsModelTests.job("a", "done", created: "2026-11-15T08:00:00Z", message: "  ")],
                "incomplete": true,
            ])
            response.headerFields[.eTag] = "\"j1\""
            return (response, body)
        }
        let model = JobsModel(scope: .all, client: transport.makeClient())
        await model.load()
        #expect(model.jobs.count == 1 && model.incomplete)
        #expect(model.jobs[0].errorText == nil)  // Leerraum zählt nicht als Meldung
        #expect(!model.hasOpenJobs && model.pollingInterval == JobPolling.slow)
        await model.load()
        #expect(transport.requests("listJobs").last?.request.headerFields[.ifNoneMatch] == "\"j1\"")
        #expect(model.jobs.count == 1 && model.error == nil)
    }
}
