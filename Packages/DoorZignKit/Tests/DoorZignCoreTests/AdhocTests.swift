import Foundation
import HTTPTypes
import Testing
@testable import DoorZignCore

@Suite @MainActor struct AdhocTests {
    static let running: [String: Any] = [
        "content": ["type": "text", "headline": "Heute geschlossen", "message": "Bitte Raum 2 nutzen"],
        "startsAt": "2026-11-14T09:00:00Z", "endsAt": "2099-01-01T00:00:00Z",
    ]

    @Test func keineNachrichtUndStarten() async throws {
        let transport = RoutingStubTransport()
        transport.on("getAdhoc") { _, _ in (HTTPResponse(status: .noContent), nil) }
        transport.on("startAdhoc") { _, body in
            let sent = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            return RoutingStubTransport.json(.created, [
                "content": sent["content"]!, "startsAt": "2026-11-14T10:00:00Z", "endsAt": "2099-01-01T00:00:00Z",
            ])
        }
        let model = AdhocModel(displayId: "d-1", client: transport.makeClient())
        await model.load()
        #expect(model.error == nil && model.running == nil)
        #expect(model.durationMinutes == 60)
        #expect(!model.canStart)  // ohne Text

        model.text.headline = "Besprechung verschoben"
        model.durationMinutes = 90
        #expect(model.canStart)
        let started = try #require(await model.start())
        #expect(started.content.headline == "Besprechung verschoben")
        #expect(model.isRunning())

        let body = try #require(transport.requests("startAdhoc").first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["durationMinutes"] as? Int == 90)
        #expect((json["content"] as? [String: Any])?["type"] as? String == "text")
    }

    @Test func laufendeNachrichtWirdUebernommenUndBeendet() async throws {
        let transport = RoutingStubTransport()
        transport.on("getAdhoc") { _, _ in RoutingStubTransport.json(.ok, AdhocTests.running) }
        transport.on("endAdhoc") { _, _ in (HTTPResponse(status: .noContent), nil) }
        let model = AdhocModel(displayId: "d-1", client: transport.makeClient())
        await model.load()
        #expect(model.isRunning())
        #expect(model.text.headline == "Heute geschlossen")
        #expect(await model.end())
        #expect(model.running == nil)
    }

    @Test func validierungsfehler() async throws {
        let transport = RoutingStubTransport()
        transport.on("startAdhoc") { _, _ in
            RoutingStubTransport.json(.unprocessableContent, ["error": [
                "code": "validation", "message": "Dieses Display hat keine Textansicht.", "fields": ["content": ["Keine Textansicht"]],
            ]])
        }
        let model = AdhocModel(displayId: "d-1", client: transport.makeClient())
        model.text.message = "Hallo"
        #expect(await model.start() == nil)
        #expect(model.error?.code == "validation")
        #expect(model.error?.statusCode == 422)
        #expect(model.error?.fields["content"] == ["Keine Textansicht"])
    }

    @Test func dauerTexte() {
        #expect(AdhocModel.label(minutes: 45) == "45 Min.")
        #expect(AdhocModel.label(minutes: 120) == "2 Std.")
        #expect(AdhocModel.label(minutes: 90) == "1 Std. 30 Min.")
    }
}
