import DoorZignAPI
import Foundation
import Testing
@testable import DoorZignCore

/// Anzeigename (decisions 48): leerer Name → MAC, wie das Backend sie liefert.
@Suite struct DisplayNamingTests {
    @Test func leererName() {
        #expect(DisplayNaming.displayName(name: "", mac: "AA:BB:CC:DD:EE:01") == "AA:BB:CC:DD:EE:01")
        #expect(DisplayNaming.displayName(name: nil, mac: "AA:BB:CC:DD:EE:01") == "AA:BB:CC:DD:EE:01")
    }

    @Test func nurLeerzeichen() {
        #expect(DisplayNaming.displayName(name: "   ", mac: "aa-bb-cc") == "aa-bb-cc")
        #expect(DisplayNaming.displayName(name: " \t\n", mac: "aa-bb-cc") == "aa-bb-cc")
    }

    @Test func gesetzterName() {
        #expect(DisplayNaming.displayName(name: "Foyer", mac: "AA:BB") == "Foyer")
        // Gesetzte Namen bleiben unverändert (kein Trimmen).
        #expect(DisplayNaming.displayName(name: " Foyer ", mac: "AA:BB") == " Foyer ")
    }

    /// Fixture-Displays; das erste bekommt einen leeren, das zweite einen Leerzeichen-Namen.
    static func displaysOhneNamen() throws -> (all: [Display], empty: Display, blank: Display) {
        var displays = try DisplayListTests.fixtureDisplays()
        try #require(displays.count >= 2)
        displays[0].name = ""
        displays[1].name = "   "
        return (displays, displays[0], displays[1])
    }

    @Test func displayZeigtMac() throws {
        let (_, empty, blank) = try Self.displaysOhneNamen()
        #expect(empty.displayName == empty.mac)
        #expect(blank.displayName == blank.mac)
    }

    @Test func sucheNachMac() throws {
        let (all, empty, _) = try Self.displaysOhneNamen()
        // Ohne Namen über die MAC auffindbar …
        #expect(DisplayListLogic.apply(all, filter: .all, search: empty.mac).map(\.id) == [empty.id])
        // … und auch mit Namen findet die Suche immer die MAC.
        let named = try #require(all.first { !$0.name.isEmpty })
        #expect(DisplayListLogic.apply(all, filter: .all, search: named.mac).map(\.id).contains(named.id))
        // Groß-/Kleinschreibung egal.
        #expect(DisplayListLogic.apply(all, filter: .all, search: empty.mac.lowercased()).map(\.id).contains(empty.id))
    }

    @Test func sortierungNachAngezeigtemNamen() throws {
        let (all, _, _) = try Self.displaysOhneNamen()
        let sorted = DisplayListLogic.apply(all, filter: .all, search: "").map(\.displayName)
        #expect(sorted == all.map(\.displayName).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func auftragOhneNamenZeigtMac() throws {
        func job(_ name: String?) throws -> Job {
            var json: [String: Any] = ["id": "j", "displayId": "d-1", "type": "identify",
                                       "status": "done", "createdAt": "2026-11-22T08:00:00Z"]
            if let name { json["displayName"] = name }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Job.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(try job("Foyer").displayLabel(mac: "AA:BB") == "Foyer")
        #expect(try job("").displayLabel(mac: "AA:BB") == "AA:BB")
        #expect(try job("  ").displayLabel(mac: "AA:BB") == "AA:BB")
        #expect(try job(nil).displayLabel(mac: "AA:BB") == "AA:BB")
        #expect(try job("").displayLabel(mac: nil) == nil)
    }
}
