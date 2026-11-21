import Foundation
import Testing
@testable import DoorZignCore

/// Verbindungslinks (decisions 45, ui-spec §1 „Verbindungslinks“).
@Suite struct LinkRoutingTests {
    static let fp = String(repeating: "ab", count: 32)
    static let edgeLink = "doorzign://edge?u=https://10.0.0.5:8443&fp=\(fp)&i=inst-1&n=Rathaus"
    static let otherEdgeLink = "doorzign://edge?u=https://10.0.0.6:8443&fp=\(fp)&i=inst-2"
    static let cloudLink = "doorzign://cloud?u=https://Firma.zeitwart.de/"
    static let invalid = "doorzign://edge?u=https://10.0.0.5:8443"  // fp und i fehlen

    static let edgeProfile = ConnectionProfile(systemType: .edge, instanceId: "inst-1",
                                               baseURL: URL(string: "https://10.0.0.5:8443/mobile/v1")!,
                                               name: "Rathaus", tlsFingerprint: fp)
    static let cloudProfile = ConnectionProfile(systemType: .cloud, instanceId: "zw-1",
                                                baseURL: URL(string: "https://firma.zeitwart.de/mobile/v1")!,
                                                name: "Firma", tlsFingerprint: nil)

    @Test func startHaeltLinkBisPhaseFeststeht() {
        #expect(LinkRouting.decide(raw: Self.edgeLink, context: .starting) == .wait)
        #expect(LinkRouting.decide(raw: Self.invalid, context: .starting) == .wait)
    }

    @Test func onboardingPrueftAuchUngueltigeLinks() {
        // Roh ans Onboarding, dort wie ein gescannter QR-Code geprüft (Fehler statt still verwerfen).
        #expect(LinkRouting.decide(raw: Self.edgeLink, context: .onboarding) == .onboarding)
        #expect(LinkRouting.decide(raw: Self.invalid, context: .onboarding) == .onboarding)
        #expect(LinkRouting.decide(raw: Self.cloudLink, context: .onboarding) == .onboarding)
    }

    @Test func anmeldeseite() {
        // Gültig (auch Cloud, auch dasselbe System): ohne Rückfrage verlassen und prüfen; ungültig: Hinweis.
        #expect(LinkRouting.decide(raw: Self.edgeLink, context: .login) == .leaveLogin)
        #expect(LinkRouting.decide(raw: Self.cloudLink, context: .login) == .leaveLogin)
        #expect(LinkRouting.decide(raw: Self.invalid, context: .login) == .invalidOnLogin)
    }

    @Test func angemeldet() {
        #expect(LinkRouting.decide(raw: Self.edgeLink, context: .signedIn(Self.edgeProfile)) == .ignore)
        #expect(LinkRouting.decide(raw: Self.otherEdgeLink, context: .signedIn(Self.edgeProfile)) == .confirmSwitch)
        #expect(LinkRouting.decide(raw: Self.cloudLink, context: .signedIn(Self.edgeProfile)) == .confirmSwitch)
        #expect(LinkRouting.decide(raw: Self.invalid, context: .signedIn(Self.edgeProfile)) == .ignore)
        // Cloud: gleiche Basis-URL (Groß-/Kleinschreibung, Schrägstrich, Standardport egal).
        #expect(LinkRouting.decide(raw: Self.cloudLink, context: .signedIn(Self.cloudProfile)) == .ignore)
        #expect(LinkRouting.decide(raw: "doorzign://cloud?u=https://firma.zeitwart.de:443", context: .signedIn(Self.cloudProfile)) == .ignore)
        #expect(LinkRouting.decide(raw: "doorzign://cloud?u=https://andere.zeitwart.de", context: .signedIn(Self.cloudProfile)) == .confirmSwitch)
        #expect(LinkRouting.decide(raw: Self.edgeLink, context: .signedIn(Self.cloudProfile)) == .confirmSwitch)
    }
}

@Suite @MainActor struct LinkGateTests {
    /// Ein Prüfschritt, der hängt, bis `finish()` aufgerufen wird.
    final class Blocker {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var started = false
        func wait() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func finish() { continuation?.resume(); continuation = nil }
    }

    @Test func linkWaehrendPruefungWirdGehaltenUndDanachUebernommen() async throws {
        let gate = LinkGate()
        let blocker = Blocker()
        var processed: [String] = []
        var firstCompleted = false
        var firstCancelled = false

        let first = Task { @MainActor in
            await gate.run {
                await blocker.wait()
                firstCancelled = Task.isCancelled
                firstCompleted = true
            }
        }
        while !blocker.started { await Task.yield() }
        #expect(gate.isBusy)

        // Zwei Links während der Prüfung: nichts abbrechen, nur der neuere wird gehalten.
        await gate.submit("link-1") { processed.append($0) }
        await gate.submit("link-2") { processed.append($0) }
        #expect(processed.isEmpty)
        #expect(gate.heldLink == "link-2")

        blocker.finish()
        await first.value
        #expect(firstCompleted && !firstCancelled)
        #expect(processed == ["link-2"])
        #expect(gate.heldLink == nil && !gate.isBusy)
    }

    @Test func ohnePruefungSofort() async {
        let gate = LinkGate()
        var processed: [String] = []
        await gate.submit("a") { processed.append($0) }
        #expect(processed == ["a"])
        #expect(gate.heldLink == nil)
    }

    @Test func verschachtelteSchritteGebenErstAmEndeFrei() async throws {
        let gate = LinkGate()
        let blocker = Blocker()
        var processed: [String] = []
        let outer = Task { @MainActor in
            await gate.run {
                await gate.run { }  // innerer Schritt fertig, äußerer läuft noch
                await blocker.wait()
            }
        }
        while !blocker.started { await Task.yield() }
        await gate.submit("x") { processed.append($0) }
        #expect(processed.isEmpty && gate.isBusy)
        blocker.finish()
        await outer.value
        #expect(processed == ["x"])
    }

    @Test func gehaltenerLinkLaeuftSelbstDurchDasGate() async throws {
        // Der übernommene Link startet seine eigene Prüfung; ein Link währenddessen wartet erneut.
        let gate = LinkGate()
        let first = Blocker(), second = Blocker()
        var processed: [String] = []
        let task = Task { @MainActor in await gate.run { await first.wait() } }
        while !first.started { await Task.yield() }
        await gate.submit("a") { raw in
            await gate.run { processed.append(raw); await second.wait() }
        }
        first.finish()
        while !second.started { await Task.yield() }
        #expect(processed == ["a"] && gate.isBusy)
        await gate.submit("b") { processed.append($0) }
        #expect(gate.heldLink == "b")
        second.finish()
        await task.value
        #expect(processed == ["a", "b"])
    }
}
