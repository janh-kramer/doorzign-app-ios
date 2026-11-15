import Foundation
import Testing
@testable import DoorZignCore

/// Auswahlregel bei mehreren Adressen (decisions 36): parallel, Master mit Vorrang, sonst erste gültige Antwort.
@Suite struct SystemProbeRaceTests {
    struct Down: Error {}

    /// Versuch, der nach `delay` Millisekunden `value` liefert oder `error` wirft.
    static func after(_ ms: Int, _ value: String? = nil, error: (any Error)? = nil) -> @Sendable () async throws -> String {
        {
            try await Task.sleep(for: .milliseconds(ms))
            if let error { throw error }
            return value ?? ""
        }
    }

    static func run(_ attempts: [@Sendable () async throws -> String], grace: Duration = .milliseconds(300)) async throws -> String {
        try await SystemProbe.race(count: attempts.count, masterGrace: grace) { try await attempts[$0]() }
    }

    @Test func masterGewinntInnerhalbDesVorrangs() async throws {
        let winner = try await Self.run([Self.after(150, "master"), Self.after(10, "zweite")])
        #expect(winner == "master")
    }

    @Test func nachDemVorrangGewinntDieErsteGueltigeAntwort() async throws {
        let start = ContinuousClock.now
        let winner = try await Self.run([Self.after(5_000, "master"), Self.after(10, "zweite"), Self.after(50, "dritte")])
        #expect(winner == "zweite")
        // Nicht auf den langsamen Master warten: Ende kurz nach Ablauf des Vorrangs.
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func masterFehlerBeendetDenVorrangSofort() async throws {
        let start = ContinuousClock.now
        let winner = try await Self.run([Self.after(20, error: Down()), Self.after(10, "zweite")], grace: .seconds(5))
        #expect(winner == "zweite")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func spaeterMasterGewinntWennSonstNiemandAntwortet() async throws {
        let winner = try await Self.run([Self.after(500, "master"), Self.after(10, error: Down())])
        #expect(winner == "master")
    }

    @Test func fingerprintFehlerHatVorrangVorUnerreichbar() async throws {
        await #expect(throws: ProbeError.fingerprintMismatch(presented: "x")) {
            _ = try await Self.run([
                Self.after(10, error: Down()),
                Self.after(20, error: ProbeError.fingerprintMismatch(presented: "x")),
            ])
        }
    }

    @Test func gueltigeAdresseSchlaegtFalschenFingerprint() async throws {
        let winner = try await Self.run([
            Self.after(10, error: ProbeError.fingerprintMismatch(presented: "x")),
            Self.after(30, "zweite"),
        ])
        #expect(winner == "zweite")
    }

    @Test func alleUnerreichbar() async throws {
        do {
            _ = try await Self.run([Self.after(10, error: Down()), Self.after(20, error: Down())])
            Issue.record("Fehler erwartet")
        } catch let error as ProbeError {
            guard case .unreachable = error else { Issue.record("unreachable erwartet, war \(error)"); return }
        }
    }

    @Test func eineAdresseOhneWartezeit() async throws {
        let winner = try await Self.run([Self.after(10, "einzige")], grace: .seconds(10))
        #expect(winner == "einzige")
    }
}
