import DoorZignAPI
import Foundation
import Testing
@testable import DoorZignCore

/// Prüft die Listenlogik mit der Vertrags-Fixture displays.json aus dem Koordinations-Repo.
@Suite struct DisplayListTests {
    static func fixtureDisplays() throws -> [Display] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../../doorzign-app-coordination/contract/fixtures/displays.json")
            .standardizedFileURL
        var data = try Data(contentsOf: url)
        // Fixtures können als OpenAPI-Example `{ "value": … }` vorliegen.
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["value"] {
            data = try JSONSerialization.data(withJSONObject: value)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Operations.ListDisplays.Output.Ok.Body.JsonPayload.self, from: data).data
    }

    @Test func filterUndSortierung() throws {
        let displays = try Self.fixtureDisplays()
        #expect(DisplayListLogic.apply(displays, filter: .all, search: "").map(\.name)
            == ["Besprechung 2", "Foyer", "Labor", "Raum 1.23", "Raum 1.24", "Sekretariat"])
        #expect(DisplayListLogic.apply(displays, filter: .offline, search: "").map(\.name) == ["Raum 1.24"])
        #expect(DisplayListLogic.apply(displays, filter: .lowBattery, search: "").map(\.name) == ["Sekretariat"])
        #expect(DisplayListLogic.apply(displays, filter: .error, search: "").map(\.name) == ["Labor"])
        #expect(DisplayListLogic.apply(displays, filter: .transferring, search: "").map(\.name) == ["Foyer"])
        #expect(DisplayListLogic.apply(displays, filter: .all, search: "raum").count == 2)
    }

    @Test func schwellen() {
        #expect(BatteryLevel(percent: 14) == .critical)
        #expect(BatteryLevel(percent: 15) == .low)
        #expect(BatteryLevel(percent: 29) == .low)
        #expect(BatteryLevel(percent: 30) == .normal)
        #expect(BatteryLevel(percent: nil) == .unknown)
        #expect(SignalQuality(rssi: -65) == .good)
        #expect(SignalQuality(rssi: -66) == .medium)
        #expect(SignalQuality(rssi: -80) == .medium)
        #expect(SignalQuality(rssi: -81) == .weak)
        #expect(SignalQuality(rssi: nil) == .unknown)
    }

    @Test func stufen() throws {
        let displays = try Self.fixtureDisplays()
        let view = try #require(displays.first { $0.level == .view })
        let edit = try #require(displays.first { $0.level == .edit })
        #expect(view.allows(.view))
        #expect(!view.allows(._switch))
        #expect(edit.allows(.edit))
    }
}
