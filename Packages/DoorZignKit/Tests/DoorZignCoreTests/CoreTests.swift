// Tests mit Swift Testing (läuft auch ohne Xcode mit den Command Line Tools).
import Foundation
import Testing
@testable import DoorZignCore

@Suite struct PairingLinkTests {
    let fp = String(repeating: "ab", count: 32)

    @Test func edgeLinkMitMehrerenAdressen() throws {
        let link = try PairingLink.parse("doorzign://edge?u=https://10.0.0.5:8443,https://gw2.local:8443/&fp=\(fp.uppercased())&i=inst-1")
        #expect(link == .edge(
            urls: [URL(string: "https://10.0.0.5:8443/mobile/v1")!, URL(string: "https://gw2.local:8443/mobile/v1")!],
            fingerprint: fp, instanceId: "inst-1", name: nil))
    }

    @Test func edgeLinkMitPercentEncodingUndDoppelpunkten() throws {
        let colon = Fingerprint.formatted(fp)
        let link = try PairingLink.parse("doorzign://edge?u=https%3A%2F%2Fa%3A8443,https%3A%2F%2Fb%3A8443&fp=\(colon)&i=x&n=Rathaus%20Nord")
        guard case .edge(let urls, let f, _, let name) = link else { Issue.record("kein Edge-Link"); return }
        #expect(urls.count == 2)
        #expect(f == fp)
        #expect(name == "Rathaus Nord")
    }

    @Test func edgeLinkOhneFingerprintScheitert() {
        #expect(throws: PairingLink.ParseError.missingParameter("fp")) {
            try PairingLink.parse("doorzign://edge?u=https://a&i=x")
        }
    }

    @Test func httpWirdAbgelehnt() {
        #expect(throws: PairingLink.ParseError.self) {
            try PairingLink.parse("doorzign://edge?u=http://a:8090&fp=\(fp)&i=x")
        }
    }

    @Test func cloudLink() throws {
        #expect(try PairingLink.parse("doorzign://cloud?u=https://firma.zeitwart.de&n=Firma")
            == .cloud(url: URL(string: "https://firma.zeitwart.de/mobile/v1")!, name: "Firma"))
    }

    @Test func fremderLink() {
        #expect(throws: PairingLink.ParseError.notDoorzign) { try PairingLink.parse("https://example.com") }
    }
}

@Suite struct APIBaseTests {
    @Test func cloudEingaben() {
        #expect(APIBase.cloud(fromInput: " Firma ")?.absoluteString == "https://firma.zeitwart.de/mobile/v1")
        #expect(APIBase.cloud(fromInput: "doorzign.example.org")?.absoluteString == "https://doorzign.example.org/mobile/v1")
        #expect(APIBase.cloud(fromInput: "https://firma.zeitwart.de/mobile/v1/")?.absoluteString == "https://firma.zeitwart.de/mobile/v1")
        #expect(APIBase.cloud(fromInput: "http://firma.zeitwart.de") == nil)
        #expect(APIBase.cloud(fromInput: "fir ma") == nil)
    }

    @Test func edgeEingaben() {
        #expect(APIBase.edge(fromInput: "192.168.1.10")?.absoluteString == "https://192.168.1.10:8443/mobile/v1")
        #expect(APIBase.edge(fromInput: "gw.local:9443")?.absoluteString == "https://gw.local:9443/mobile/v1")
    }
}

@Suite struct FingerprintTests {
    @Test func normalisierungUndKurzform() {
        let raw = (0..<32).map { String(format: "%02X", $0) }.joined(separator: ":")
        let n = Fingerprint.normalize(raw)!
        #expect(n.count == 64)
        #expect(Fingerprint.short(n) == "00:01:02:03 … 1C:1D:1E:1F")
        #expect(Fingerprint.normalize("abc") == nil)
        #expect(Fingerprint.normalize(String(repeating: "zz", count: 32)) == nil)
    }
}

@Suite struct PKCETests {
    @Test func rfc7636Beispiel() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func callback() throws {
        let p = PKCE()
        #expect(try SSOFlow.code(from: URL(string: "doorzign://auth/callback?code=abc&state=\(p.state)")!, expectedState: p.state) == "abc")
        #expect(throws: SSOFlow.CallbackError.stateMismatch) {
            try SSOFlow.code(from: URL(string: "doorzign://auth/callback?code=abc&state=falsch")!, expectedState: p.state)
        }
        #expect(throws: SSOFlow.CallbackError.provider(code: "access_denied")) {
            try SSOFlow.code(from: URL(string: "doorzign://auth/callback?error=access_denied&state=\(p.state)")!, expectedState: p.state)
        }
        // Zeitwart (6c5bcd006): ungültige Parameter → invalid_request; expired/provider_error werden verstanden.
        for code in ["invalid_request", "expired", "provider_error", "unbekannt"] {
            #expect(throws: SSOFlow.CallbackError.provider(code: code)) {
                try SSOFlow.code(from: URL(string: "doorzign://auth/callback?error=\(code)&state=\(p.state)")!, expectedState: p.state)
            }
        }
    }

    @Test func callbackTexte() throws {
        let de = try #require(CoreL10n.bundle(language: "de"))
        CoreL10n.$bundleOverride.withValue(de) {
            #expect(SSOFlow.message(for: .provider(code: "invalid_request")) == "Die Anmeldung konnte nicht gestartet werden. Bitte erneut versuchen.")
            #expect(SSOFlow.message(for: .provider(code: "expired")) == "Die Anmeldung hat zu lange gedauert. Bitte erneut versuchen.")
            #expect(SSOFlow.message(for: .provider(code: "provider_error")) == "Die Anmeldung beim Anbieter ist fehlgeschlagen.")
            #expect(SSOFlow.message(for: .stateMismatch) == "Ungültige Antwort der Anmeldung. Bitte erneut versuchen.")
            // invalid_grant beim Code-Tausch (abgelaufen, schon benutzt, falscher Verifier).
            let grant = APIError(code: "invalid_grant", message: "Server", statusCode: 401).forSSO
            #expect(grant.message == "Die Anmeldung ist abgelaufen. Bitte erneut anmelden.")
            #expect(APIError(code: "forbidden", message: "x").forSSO.message == "x")
        }
    }

    @Test func startURL() {
        let url = SSOFlow.startURL(baseURL: URL(string: "https://f.zeitwart.de/mobile/v1")!, provider: "ms", pkce: PKCE(), deviceName: "iPhone von X")!
        #expect(url.absoluteString.hasPrefix("https://f.zeitwart.de/mobile/v1/auth/sso/start?provider=ms&redirect_uri=doorzign://auth/callback"))
        #expect(url.absoluteString.contains("code_challenge_method=S256"))
    }
}

@Suite struct DateTranscoderTests {
    @Test func mitUndOhneSekundenbruchteile() throws {
        let t = LenientDateTranscoder()
        let plain = try t.decode("2026-11-14T10:15:00Z")
        #expect(abs(try t.decode("2026-11-14T10:15:00.000000Z").timeIntervalSince(plain)) < 0.001)
        #expect(abs(try t.decode("2026-11-14T10:15:00.5Z").timeIntervalSince(plain) - 0.5) < 0.001)
        #expect(try t.encode(plain) == "2026-11-14T10:15:00Z")
        #expect(throws: (any Error).self) { try t.decode("14.11.2026") }
    }
}

@Suite struct VersionTests {
    @Test func vergleich() {
        #expect(SystemInfo.compare("1.10.0", "1.9.3") == .orderedDescending)
        #expect(SystemInfo.compare("1.0", "1.0.0") == .orderedSame)
        #expect(SystemInfo.compare("1.0.0", "1.0.1") == .orderedAscending)
    }
}

@Suite struct InstanceCacheTests {
    @Test func trennungUndLoeschen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = InstanceCache(root: root)
        #expect(cache.directory(for: "../x").lastPathComponent == ".._x")
        for id in ["a", "b"] {
            try FileManager.default.createDirectory(at: cache.directory(for: id), withIntermediateDirectories: true)
        }
        try cache.wipeAll(except: "a")
        #expect(FileManager.default.fileExists(atPath: cache.directory(for: "a").path))
        #expect(!FileManager.default.fileExists(atPath: cache.directory(for: "b").path))
        try cache.wipeAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Suite struct TokenManagerTests {
    actor Counter { var n = 0; func inc() -> Int { n += 1; return n } }
    final class Flag: @unchecked Sendable { var set = false }

    @Test func gleichzeitigeRefreshsWerdenSerialisiert() async throws {
        let counter = Counter()
        let manager = TokenManager(
            tokens: Tokens(accessToken: "alt", refreshToken: "r0", expiresAt: .distantFuture),
            refresher: { _ in
                let n = await counter.inc()
                try await Task.sleep(nanoseconds: 50_000_000)
                return Tokens(accessToken: "neu\(n)", refreshToken: "r\(n)", expiresAt: .distantFuture)
            },
            persist: { _ in }, onSessionExpired: {})
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await manager.refresh(rejectedAccessToken: "alt") } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(results) == ["neu1"])
        #expect(await counter.n == 1)
    }

    @Test func abgelaufenesTokenWirdVorabErneuert() async throws {
        let manager = TokenManager(
            tokens: Tokens(accessToken: "alt", refreshToken: "r0", expiresAt: Date().addingTimeInterval(5)),
            refresher: { _ in Tokens(accessToken: "neu", refreshToken: "r1", expiresAt: .distantFuture) },
            persist: { _ in }, onSessionExpired: {})
        #expect(try await manager.validAccessToken() == "neu")
    }

    @Test func widerrufenerRefreshMeldetAb() async {
        let expired = Flag()
        let manager = TokenManager(
            tokens: Tokens(accessToken: "alt", refreshToken: "r0", expiresAt: .distantFuture),
            refresher: { _ in throw AuthError.notAuthenticated },
            persist: { _ in }, onSessionExpired: { expired.set = true })
        await #expect(throws: AuthError.notAuthenticated) { try await manager.refresh(rejectedAccessToken: "alt") }
        #expect(expired.set)
        #expect(await manager.hasTokens == false)
    }

    @Test func netzfehlerBeimRefreshBehaeltTokens() async {
        let manager = TokenManager(
            tokens: Tokens(accessToken: "alt", refreshToken: "r0", expiresAt: .distantFuture),
            refresher: { _ in throw URLError(.notConnectedToInternet) },
            persist: { _ in }, onSessionExpired: {})
        await #expect(throws: URLError.self) { try await manager.refresh(rejectedAccessToken: "alt") }
        #expect(await manager.hasTokens)
    }

    @Test func invalidateIgnoriertVeraltetesToken() async {
        let manager = TokenManager(
            tokens: Tokens(accessToken: "aktuell", refreshToken: "r0", expiresAt: .distantFuture),
            refresher: { _ in throw URLError(.unknown) }, persist: { _ in }, onSessionExpired: {})
        await manager.invalidate(rejectedAccessToken: "alt")
        #expect(await manager.hasTokens)
        await manager.invalidate(rejectedAccessToken: "aktuell")
        #expect(await manager.hasTokens == false)
    }
}
