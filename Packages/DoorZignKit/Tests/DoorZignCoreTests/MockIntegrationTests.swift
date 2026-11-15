// Integrationstest gegen den Prism-Mock. Läuft nur, wenn DOORZIGN_MOCK_URL gesetzt ist, z. B.:
//   DOORZIGN_MOCK_URL=http://localhost:4010 ./scripts/test-kit.sh
import DoorZignAPI
import Foundation
import Testing
@testable import DoorZignCore

private let mockURL = ProcessInfo.processInfo.environment["DOORZIGN_MOCK_URL"].flatMap(URL.init(string:))

@Suite(.enabled(if: mockURL != nil, "DOORZIGN_MOCK_URL nicht gesetzt"))
@MainActor
struct MockIntegrationTests {
    @Test func anmeldenLadenAbmelden() async throws {
        let url = try #require(mockURL)
        let store = InMemoryCredentialStore()
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = AppSession(appVersion: "1.0.0", deviceName: "Test", store: store, instanceCache: InstanceCache(root: cacheRoot))

        await session.bootstrap()
        guard case .onboarding = session.phase else { Issue.record("erwartet: Onboarding"); return }

        let probe = try await SystemProbe.probe(urls: [url], trust: .system)
        #expect(probe.system.has(.authPassword))
        let error = await session.prepareLogin(probe: probe, pinnedFingerprint: nil)
        #expect(error == nil)
        guard case .login(let context) = session.phase else { Issue.record("erwartet: Anmeldung"); return }
        #expect(context.passwordEnabled)

        try await session.login(context: context, username: "demo", password: "demo")
        guard case .signedIn(let signedIn) = session.phase else { Issue.record("erwartet: angemeldet"); return }
        #expect(try store.loadProfile()?.instanceId == probe.system.instanceId)
        #expect(try store.loadTokens(instanceId: probe.system.instanceId) != nil)

        let displays = try await signedIn.client.listDisplays().ok.body.json.data
        #expect(!displays.isEmpty)
        let slots = try await signedIn.client.listSlots(path: .init(displayId: displays[0].id)).ok.body.json.data
        #expect(slots.count == 3)
        let jobs = try await signedIn.client.listJobs().ok.body.json.data
        #expect(!jobs.isEmpty)

        // Displayliste mit ETag und Vorschau über den PreviewLoader.
        let list = DisplayListModel(client: signedIn.client)
        await list.load()
        #expect(list.error == nil)
        #expect(list.visibleDisplays.count == displays.count)
        let first = list.visibleDisplays[0]
        let png = await signedIn.previews.preview(displayId: first.id, slot: first.activeSlot, expectedEtag: first.activePreviewEtag)
        #expect(png != nil)

        // Displaydetail mit allen Abschnitten und einer Aktion.
        await session.refreshSignedInInfo()
        guard case .signedIn(let withSystem) = session.phase else { return }
        let editable = try #require(list.displays.first { $0.level == .edit })
        let detail = DisplayDetailModel(displayId: editable.id, initial: editable, client: signedIn.client, system: withSystem.system)
        await detail.load()
        #expect(detail.error == nil)
        #expect(detail.slots.count == 3)
        #expect(!detail.jobs.isEmpty)
        // Standardbeispiel von GET /displays/{id} ist display_edit.
        #expect(detail.canEdit)
        try await detail.activate(slot: 2)
        try await detail.identify()
        try await detail.resend()
        #expect(detail.showsAdhoc && detail.showsSchedules)

        // Zeitpläne: laden, anlegen, ändern mit If-Match, umschalten, löschen.
        let schedules = SchedulesModel(displayId: editable.id, client: signedIn.client)
        await schedules.load()
        #expect(schedules.error == nil)
        #expect(!schedules.schedules.isEmpty)
        var draft = ScheduleDraft()
        draft.name = "Mock"
        if case .failed(let failure) = await schedules.save(draft, existing: nil) { Issue.record("anlegen: \(failure.message)") }
        let existing = try #require(schedules.schedules.first)
        if case .failed(let failure) = await schedules.save(ScheduleDraft(existing), existing: existing) {
            Issue.record("ändern: \(failure.message)")
        }
        #expect(await schedules.setEnabled(!existing.enabled, for: existing) == nil)
        #expect(await schedules.delete(existing) == nil)

        // Übertragungen: pro Display und global (ETag beim zweiten Laden).
        let displayJobs = JobsModel(scope: .display(editable.id), client: signedIn.client)
        await displayJobs.load()
        #expect(displayJobs.error == nil && !displayJobs.jobs.isEmpty)
        let allJobs = JobsModel(scope: .all, client: signedIn.client)
        await allJobs.load()
        await allJobs.load()
        #expect(allJobs.error == nil && !allJobs.jobs.isEmpty)

        // Medienbibliothek: Liste dekodieren. Prism liefert für GET /media/{id} kein echtes Bild,
        // die Miniatur ist daher nicht prüfbar (abgedeckt durch MediaLibraryTests).
        #expect(withSystem.system?.has(.mediaLibrary) == true)
        let library = MediaLibraryModel(client: signedIn.client)
        await library.load()
        #expect(library.error == nil)
        #expect(!library.items.isEmpty)
        _ = await library.thumbnails.thumbnail(for: library.items[0].id)

        // Editor: laden, Vorschau, Bild hochladen (Multipart), Kalender prüfen, speichern mit If-Match.
        let editor = SlotEditorModel(displayId: editable.id, slot: 2, display: detail.display,
                                     client: signedIn.client, system: withSystem.system)
        await editor.load()
        #expect(editor.loadError == nil)
        // POST /media (multipart) lässt sich mit Prism 4 nicht mocken: Prism wertet Multipart-Bodies nicht aus
        // und antwortet immer 422 („request.body must be object“), auch bei curl -F. Der Upload ist durch
        // MediaUploadTests (Stub-Transport, prüft den echten Body) abgedeckt.
        editor.draft.kind = .text
        editor.draft.text.title = "Geändert"
        #expect(await editor.save() != nil)
        #expect(editor.saveError == nil)
        editor.draft.calendar.url = "webcal://example.org/kalender.ics"
        await editor.checkCalendar()
        #expect(editor.calendarCheck != .idle && editor.calendarCheck != .running)

        // Ad-hoc: laufende Nachricht laden, ersetzen, beenden.
        let adhoc = AdhocModel(displayId: editable.id, client: signedIn.client)
        await adhoc.load()
        #expect(adhoc.error == nil)
        adhoc.text.headline = "Heute geschlossen"
        #expect(await adhoc.start() != nil)
        #expect(adhoc.error == nil)
        #expect(await adhoc.end())
        #expect(detail.runningAction == nil)

        guard case .signedIn(let refreshed) = session.phase else { return }
        #expect(refreshed.me != nil)

        try FileManager.default.createDirectory(at: cacheRoot.appendingPathComponent("x"), withIntermediateDirectories: true)
        await session.signOut()
        guard case .onboarding = session.phase else { Issue.record("erwartet: Onboarding nach Abmelden"); return }
        #expect(try store.loadProfile() == nil)
        #expect(try store.loadTokens(instanceId: probe.system.instanceId) == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.path))
    }
}
