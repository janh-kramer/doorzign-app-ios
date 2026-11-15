// Tests gegen ein echtes Backend (nur öffentliche Endpunkte, ohne Zugangsdaten). Nur mit DOORZIGN_LIVE_URL, z. B.:
//   DOORZIGN_LIVE_URL=http://localhost/mobile/v1 ./scripts/test-kit.sh --filter LiveBackend
import DoorZignAPI
import Foundation
import Testing
@testable import DoorZignCore

private let liveURL = ProcessInfo.processInfo.environment["DOORZIGN_LIVE_URL"].flatMap(URL.init(string:))

@Suite(.enabled(if: liveURL != nil, "DOORZIGN_LIVE_URL nicht gesetzt"))
@MainActor
struct LiveBackendTests {
    @Test func oeffentlicheEndpunkteUndFehlerformat() async throws {
        let url = try #require(liveURL)
        let probe = try await SystemProbe.probe(urls: [url], trust: .system)
        #expect(probe.system.compatibility(appVersion: "1.0.0") == .compatible)
        #expect(!probe.system.instanceId.isEmpty)
        #expect(probe.system.raw.mediaMaxBytes > 0)

        let session = AppSession(appVersion: "1.0.0", deviceName: "Test", store: InMemoryCredentialStore(),
                                 instanceCache: InstanceCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        #expect(await session.prepareLogin(probe: probe, pinnedFingerprint: nil) == nil)
        guard case .login(let context) = session.phase else { Issue.record("erwartet: Anmeldung"); return }
        #expect(context.passwordEnabled || !context.browserProviders.isEmpty || !context.passwordProviders.isEmpty)

        // Ohne Token: 401 im Vertragsformat.
        let connection = ClientFactory.makeConnection(baseURL: url, trust: .system)
        let output = try await connection.client.listDisplays()
        let error = try #require(APIError.from(output: output))
        #expect(error.statusCode == 401)
        #expect(error.code == "unauthorized" || error.code == "token_expired")
        #expect(!error.message.isEmpty)

        // Falsche Zugangsdaten: 401 bzw. 422/429 mit deutscher Meldung, kein Absturz beim Decodieren.
        do {
            try await session.login(context: context, username: "gibt-es-nicht@example.invalid", password: "falsch")
            Issue.record("Anmeldung mit falschen Daten darf nicht gelingen")
        } catch let apiError as APIError {
            #expect([401, 422, 429].contains(apiError.statusCode ?? 0))
            #expect(!apiError.message.isEmpty)
        }
    }
}

/// Kompletter Ablauf gegen ein echtes Backend mit Testbenutzern (nur lokale Entwicklung). Umgebungsvariablen:
///   DOORZIGN_LIVE_URL       Basis-URL inkl. /mobile/v1 (Cloud, System-Trust)
///   DOORZIGN_LIVE_LINK      alternativ: Edge-Pairing-Link doorzign://edge?u=…&fp=…&i=… (echtes CA-Pinning)
///   DOORZIGN_LIVE_PASSWORD  Passwort der Testbenutzer
///   DOORZIGN_LIVE_PREFIX    Präfix der Benutzernamen (Standard: mobile-conformance-) → <prefix>view|switch|edit
///   DOORZIGN_LIVE_DISPLAY   Name des freigegebenen Displays (Standard: Konformität A)
///   DOORZIGN_LIVE_HIDDEN    Name eines nicht freigegebenen Displays (Standard: Konformität B)
///   DOORZIGN_LIVE_MUTATE=1  auch zustandsändernde Schritte (Umschalten, Ad-hoc); stellt Ansicht 1 wieder her
/// Nicht parallel zur Konformitätssuite laufen lassen (gleiche Benutzer).
private enum Live {
    static let env = ProcessInfo.processInfo.environment
    static let password = env["DOORZIGN_LIVE_PASSWORD"]
    static let prefix = env["DOORZIGN_LIVE_PREFIX"] ?? "mobile-conformance-"
    static let display = env["DOORZIGN_LIVE_DISPLAY"] ?? "Konformität A"
    static let hidden = env["DOORZIGN_LIVE_HIDDEN"] ?? "Konformität B"
    static let mutate = env["DOORZIGN_LIVE_MUTATE"] == "1"
    static let link = env["DOORZIGN_LIVE_LINK"].flatMap { try? PairingLink.parse($0) }
    static var enabled: Bool { (liveURL != nil || link != nil) && password != nil }

    /// Wie das Onboarding: Edge-Link → Probe mit gepinnter CA und erwarteter Instanz; sonst Cloud-URL.
    @MainActor
    static func connect(_ session: AppSession) async throws {
        if case .edge(let urls, let fingerprint, let instanceId, _)? = link {
            let probe = try await SystemProbe.probe(urls: urls, trust: .pinned(fingerprint: fingerprint),
                                                    expectedInstanceId: instanceId)
            #expect(probe.presentedFingerprint == fingerprint)
            #expect(await session.prepareLogin(probe: probe, pinnedFingerprint: fingerprint, alternativeURLs: urls) == nil)
        } else {
            let probe = try await SystemProbe.probe(urls: [try #require(liveURL)], trust: .system)
            #expect(await session.prepareLogin(probe: probe, pinnedFingerprint: nil) == nil)
        }
    }

    static func trust(_ profile: ConnectionProfile) -> TrustPolicy { ClientFactory.trustPolicy(for: profile) }
}

@Suite(.enabled(if: Live.enabled, "DOORZIGN_LIVE_URL/DOORZIGN_LIVE_PASSWORD nicht gesetzt"), .serialized)
@MainActor
struct LiveFlowTests {
    /// Meldet `level` an und liefert Sitzung, Kontext und Speicher.
    func signIn(_ level: String) async throws -> (AppSession, SignedInContext, InMemoryCredentialStore) {
        let store = InMemoryCredentialStore()
        let session = AppSession(appVersion: "1.0.0", deviceName: "iOS-Livetest \(level)", store: store,
                                 instanceCache: InstanceCache(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        try await Live.connect(session)
        guard case .login(let login) = session.phase else { throw APIError(code: "test", message: "keine Anmeldeseite") }
        try await session.login(context: login, username: Live.prefix + level, password: try #require(Live.password))
        await session.refreshSignedInInfo()
        guard case .signedIn(let context) = session.phase else { throw APIError(code: "test", message: "nicht angemeldet") }
        return (session, context, store)
    }

    func findDisplay(_ context: SignedInContext) async throws -> Display {
        let list = DisplayListModel(client: context.client)
        await list.load()
        #expect(list.error == nil)
        #expect(!list.displays.contains { $0.name == Live.hidden }, "fremdes Display darf nicht sichtbar sein")
        return try #require(list.displays.first { $0.name == Live.display }, "\(Live.display) nicht gefunden")
    }

    /// Edge: falsche CA bzw. falsche Instanz müssen abgelehnt werden, ohne Anfrage an /system zu beantworten.
    @Test func edgePinningNegativ() async throws {
        guard case .edge(let urls, let fingerprint, let instanceId, _)? = Live.link else { return }
        let wrong = String(repeating: "0", count: 64)
        do {
            _ = try await SystemProbe.probe(urls: urls, trust: .pinned(fingerprint: wrong))
            Issue.record("falscher Fingerprint darf nicht verbinden")
        } catch let error as ProbeError {
            #expect(error == .fingerprintMismatch(presented: fingerprint))
        }
        do {
            _ = try await SystemProbe.probe(urls: urls, trust: .pinned(fingerprint: fingerprint), expectedInstanceId: "andere-instanz")
            Issue.record("falsche Instanz darf nicht verbinden")
        } catch let error as ProbeError {
            if case .instanceMismatch(_, let actual) = error { #expect(actual == instanceId) } else { Issue.record("\(error)") }
        }
        // Erster Kontakt ohne QR: Fingerprint wird zur Bestätigung erfasst und entspricht der CA.
        let captured = try await SystemProbe.probe(urls: urls, trust: .captureForConfirmation)
        #expect(captured.presentedFingerprint == fingerprint)
    }

    @Test func viewDarfNurAnsehen() async throws {
        let (session, context, _) = try await signIn("view")
        let display = try await findDisplay(context)
        #expect(display.level == .view)
        let detail = DisplayDetailModel(displayId: display.id, initial: display, client: context.client, system: context.system)
        await detail.load()
        #expect(detail.error == nil && detail.slots.count == 3)
        #expect(!detail.canSwitch && !detail.canEdit)
        // Das Backend muss die Aktion trotzdem verweigern (403).
        await #expect(throws: APIError.self) { try await detail.identify() }
        if context.system?.has(.mediaLibrary) == true {
            // Bibliothek nur mit edit auf mindestens einem Display.
            let library = MediaLibraryModel(client: context.client)
            await library.load()
            #expect(library.error?.statusCode == 403)
        }
        await session.signOut()
    }

    @Test func editVollerAblauf() async throws {
        let (session, context, store) = try await signIn("edit")
        let display = try await findDisplay(context)
        #expect(display.level == .edit)

        let detail = DisplayDetailModel(displayId: display.id, initial: display, client: context.client, system: context.system)
        await detail.load()
        #expect(detail.error == nil)
        #expect(detail.slots.count == 3)
        #expect(detail.canEdit)

        // Vorschau der aktiven Ansicht (PNG).
        let png = await context.previews.preview(displayId: display.id, slot: display.activeSlot, expectedEtag: display.activePreviewEtag)
        #expect(png?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        // Übertragungen pro Display und global (inkl. ETag/304 beim zweiten Laden).
        let jobs = JobsModel(scope: .display(display.id), client: context.client)
        await jobs.load()
        #expect(jobs.error == nil)
        let allJobs = JobsModel(scope: .all, client: context.client)
        await allJobs.load()
        await allJobs.load()
        #expect(allJobs.error == nil)
        #expect(!allJobs.jobs.contains { $0.displayName == Live.hidden }, "Aufträge fremder Displays dürfen nicht sichtbar sein")

        // Editor lesend: laden und Live-Vorschau des gespeicherten Inhalts.
        let editor = SlotEditorModel(displayId: display.id, slot: display.activeSlot, display: detail.display,
                                     client: context.client, system: context.system)
        await editor.load()
        #expect(editor.loadError == nil)

        if Live.mutate {
            do {
                try await mutatingFlow(context: context, display: display, detail: detail)
            } catch {
                Issue.record("mutierender Ablauf: \(error)")
            }
            // Ausgangszustand immer wiederherstellen: Ansicht 1 aktiv, keine Ad-hoc-Nachricht.
            _ = await AdhocModel(displayId: display.id, client: context.client).end()
            await detail.load()
            if detail.display?.activeSlot != 1 { try await detail.activate(slot: 1) }
            await detail.load()
            #expect(detail.display?.activeSlot == 1)
            #expect(detail.adhoc == nil)
        }

        // Abmelden widerruft die Tokens serverseitig.
        let tokens = try #require(try store.loadTokens(instanceId: context.profile.instanceId))
        await session.signOut()
        let probeClient = ClientFactory.makeConnection(baseURL: context.profile.baseURL, trust: Live.trust(context.profile)).client
        let refreshed = try await probeClient.refreshToken(body: .json(.init(refreshToken: tokens.refreshToken)))
        if case .ok = refreshed { Issue.record("Refresh-Token muss nach dem Abmelden ungültig sein") }
    }

    /// Umschalten, Editor mit Bild-Upload und Bibliothek (Original wird wiederhergestellt), 412, Ad-hoc, Zeitpläne.
    func mutatingFlow(context: SignedInContext, display: Display, detail: DisplayDetailModel) async throws {
        // Umschalten auf eine andere Ansicht; Auftrag läuft über den Simulator durch.
        let target = try #require(detail.slots.first { $0.slot != 1 && !$0.content.isDeactivated })
        try await detail.activate(slot: target.slot)
        #expect(!detail.jobs.isEmpty)
        try await detail.activate(slot: 1)

        // Body-lose POSTs (identify, resend) über h2 – Edge hing hier bis zum Timeout (gemeldet 2026-11-15).
        if detail.canIdentify {
            let started = Date()
            try await detail.identify()
            #expect(Date().timeIntervalSince(started) < 5, "identify zu langsam (body-loser POST über h2?)")
        }
        let resendStarted = Date()
        let resendCount = try await detail.resend()
        #expect(Date().timeIntervalSince(resendStarted) < 5, "resend zu langsam (body-loser POST über h2?)")
        #expect((0...3).contains(resendCount))

        // Editor: inaktive Ansicht 3 (bzw. 2) bearbeiten, danach Original zurückschreiben.
        let slotNumber = detail.slots.contains { $0.slot == 3 && $0.editable } ? 3 : 2
        let editor = SlotEditorModel(displayId: display.id, slot: slotNumber, display: detail.display,
                                     client: context.client, system: context.system)
        await editor.load()
        #expect(editor.loadError == nil)
        let originalContent = try #require(editor.original?.content)

        var uploadedId: String?
        if context.system?.has(.mediaUpload) == true {
            editor.draft.kind = .image
            await editor.uploadImage(try ImagePreparationTests.makePNG(width: 1600, height: 1200))
            #expect(editor.uploadError == nil, "\(editor.uploadError ?? "")")
            uploadedId = editor.draft.image.mediaId
            #expect(uploadedId != nil)
            let saved = await editor.save()
            #expect(saved != nil, "\(editor.saveError?.message ?? "")")
            if case .image(let image)? = saved?.content { #expect(image.mediaId == uploadedId) }
        }

        if context.system?.has(.mediaLibrary) == true {
            let library = MediaLibraryModel(client: context.client)
            await library.load()
            #expect(library.error == nil, "\(library.error?.message ?? "")")
            let pick = try #require(library.items.first { $0.id == uploadedId } ?? library.items.first)
            let thumb = await library.thumbnails.thumbnail(for: pick.id)
            #expect(thumb?.prefix(2) == Data([0xFF, 0xD8]), "Miniatur muss als JPEG ankommen")
            editor.draft.kind = .image
            editor.selectMedia(pick.id)
            if editor.isDirty {
                #expect(await editor.save() != nil, "\(editor.saveError?.message ?? "")")
            }
            #expect(editor.draft.image.mediaId == pick.id)
        }

        // Konflikt: veraltetes ETag → 412.
        let staleOutput = try await context.client.updateSlot(
            path: .init(displayId: display.id, slot: slotNumber),
            headers: .init(ifMatch: "\"veraltet\""),
            body: .json(originalContent)
        )
        if case .preconditionFailed = staleOutput {} else { Issue.record("veraltetes If-Match muss 412 liefern") }

        // Original wiederherstellen (ohne If-Match).
        let restored = try expect(try await context.client.updateSlot(
            path: .init(displayId: display.id, slot: slotNumber),
            headers: .init(),
            body: .json(originalContent)
        )) { try $0.ok.body.json }
        #expect(restored.content == originalContent)

        // Ad-hoc.
        if detail.showsAdhoc {
            let adhoc = AdhocModel(displayId: display.id, client: context.client)
            adhoc.text.headline = "iOS-Livetest"
            adhoc.durationMinutes = 15
            #expect(await adhoc.start() != nil, "\(adhoc.error?.message ?? "")")
            #expect(await adhoc.end())
        }

        // Zeitpläne: anlegen (weit in der Zukunft, damit nichts umschaltet), ändern, 412, Schalter, löschen.
        if detail.showsSchedules {
            let schedules = SchedulesModel(displayId: display.id, client: context.client)
            await schedules.load()
            #expect(schedules.error == nil)
            let before = schedules.schedules.count
            var draft = ScheduleDraft()
            draft.name = "iOS-Livetest"
            draft.slot = 2
            draft.enabled = false
            draft.start = ClockTime(hour: 3, minute: 0)
            draft.end = ClockTime(hour: 2, minute: 30)  // über Mitternacht
            let future = Calendar(identifier: .gregorian).date(byAdding: .day, value: 300, to: Date())!
            draft.validFrom = CalendarDay(date: future)
            draft.validUntil = CalendarDay(date: future)
            guard case .saved(let created) = await schedules.save(draft, existing: nil) else {
                Issue.record("Zeitplan anlegen fehlgeschlagen"); return
            }
            #expect(created.start == "03:00" && created.end == "02:30")
            draft.name = "iOS-Livetest geändert"
            guard case .saved(let updated) = await schedules.save(draft, existing: created) else {
                Issue.record("Zeitplan ändern fehlgeschlagen")
                _ = await schedules.delete(created)
                return
            }
            #expect(updated.etag != created.etag)
            #expect(await schedules.save(draft, existing: created) == .conflict)
            #expect(await schedules.setEnabled(true, for: updated) == nil)
            let toDelete = schedules.schedules.first { $0.id == created.id } ?? updated
            #expect(await schedules.delete(toDelete) == nil)
            await schedules.load()
            #expect(schedules.schedules.count == before)
        }
    }

    /// Eigener Login (Diebstahlerkennung der Rotation nicht mit anderen Läufen vermischen).
    @Test func refreshRotation() async throws {
        let (session, context, store) = try await signIn("switch")
        let before = try #require(try store.loadTokens(instanceId: context.profile.instanceId))
        let client = ClientFactory.makeConnection(baseURL: context.profile.baseURL, trust: Live.trust(context.profile)).client

        let first = try expect(try await client.refreshToken(body: .json(.init(refreshToken: before.refreshToken)))) { try $0.ok.body.json }
        #expect(first.refreshToken != before.refreshToken)
        // Gnadenfrist: derselbe alte Refresh-Token liefert innerhalb von 60 s dasselbe neue Paar.
        let again = try expect(try await client.refreshToken(body: .json(.init(refreshToken: before.refreshToken)))) { try $0.ok.body.json }
        #expect(again.accessToken == first.accessToken && again.refreshToken == first.refreshToken)
        // Mit dem neuen Access-Token funktioniert /me.
        let manager = TokenManager(
            tokens: Tokens(accessToken: first.accessToken, refreshToken: first.refreshToken, expiresAt: first.expiresAt),
            refresher: { _ in throw AuthError.notAuthenticated }, persist: { _ in }, onSessionExpired: {})
        let authed = ClientFactory.makeConnection(baseURL: context.profile.baseURL, trust: Live.trust(context.profile),
                                                  middlewares: [AuthMiddleware(tokens: manager)]).client
        let me = try expect(try await authed.getMe()) { try $0.ok.body.json }
        #expect(me.username == Live.prefix + "switch")

        // Aufräumen: dieses Gerät mit dem aktuellen Refresh-Token abmelden.
        _ = try? await client.logout(body: .json(.init(refreshToken: first.refreshToken)))
        _ = session
    }
}
