import DoorZignAPI
import Foundation
import Observation
import OpenAPIRuntime

/// Zustand des Editors einer Ansicht (ui-spec §4).
@MainActor
@Observable
public final class SlotEditorModel {
    public let displayId: String
    public let slotNumber: Int

    public private(set) var display: Display?
    public private(set) var original: Slot?
    public private(set) var originalDraft: SlotDraft?
    public var draft = SlotDraft()

    public private(set) var isLoading = false
    public private(set) var loadError: APIError?

    // Vorschau
    public private(set) var previewPNG: Data?
    public private(set) var previewError: String?
    public private(set) var isRenderingPreview = false

    // Speichern
    public private(set) var isSaving = false
    public private(set) var saveError: APIError?
    /// 412: Inzwischen von jemand anderem geändert.
    public private(set) var hasConflict = false

    // Bild
    public private(set) var isUploading = false
    public private(set) var uploadError: String?

    // Kalender
    public enum CalendarCheck: Equatable, Sendable {
        case idle, running
        case ok(eventCount: Int?)
        case failed(String)
    }
    public private(set) var calendarCheck: CalendarCheck = .idle

    /// Wartezeit nach der letzten Änderung, bevor die Vorschau gerendert wird.
    public static let previewDebounce: Duration = .milliseconds(600)

    @ObservationIgnored private let client: Client
    @ObservationIgnored private let system: SystemInfo?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    public init(displayId: String, slot: Int, display: Display?, client: Client, system: SystemInfo?) {
        self.displayId = displayId
        self.slotNumber = slot
        self.display = display
        self.client = client
        self.system = system
    }

    // MARK: Abgeleitete Zustände

    public var isDirty: Bool { originalDraft != nil && draft != originalDraft }

    /// Nur lesbar: Ansicht nicht bearbeitbar oder Zeitwart-Raumanzeige.
    public var isReadOnly: Bool {
        guard let original else { return true }
        if !original.editable { return true }
        if case .calendar(let calendar) = original.content, calendar.source == .zeitwart { return true }
        return false
    }

    public var isActiveSlot: Bool { display?.activeSlot == slotNumber }

    /// Wählbare Typen. `deactivated` erscheint immer, ist aber für die aktive Ansicht gesperrt (`isKindEnabled`).
    public var availableKinds: [SlotDraft.Kind] {
        var kinds: [SlotDraft.Kind] = [.text]
        if canUploadImage || canUseMediaLibrary || originalDraft?.kind == .image { kinds.append(.image) }
        if canUseICal || originalDraft?.kind == .calendar { kinds.append(.calendar) }
        kinds.append(.deactivated)
        return kinds
    }

    public func isKindEnabled(_ kind: SlotDraft.Kind) -> Bool {
        switch kind {
        case .deactivated: !isActiveSlot
        case .calendar: canUseICal
        case .image: canUploadImage || canUseMediaLibrary
        case .text: true
        }
    }

    /// Neues Foto hochladen (Feature `media.upload`).
    public var canUploadImage: Bool { system?.has(.mediaUpload) ?? false }

    /// „Aus Bibliothek“ (Feature `media.library`, aktuell nur Edge).
    public var canUseMediaLibrary: Bool { system?.has(.mediaLibrary) ?? false }

    /// iCal nur auf Ansicht 1, mit Kalenderlizenz und Feature `calendar.ical`.
    public var canUseICal: Bool {
        slotNumber == 1 && (display?.license.calendar ?? false) && (system?.has(.calendarICal) ?? false)
    }

    public var canSave: Bool {
        !isReadOnly && isDirty && draft.content != nil && !isSaving && !isUploading
            && !(draft.kind == .deactivated && isActiveSlot)
    }

    // MARK: Laden

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let slotResult = expect(try await client.getSlot(path: .init(displayId: displayId, slot: slotNumber))) {
                try $0.ok.body.json
            }
            async let displayResult = try? client.getDisplay(path: .init(displayId: displayId)).ok.body.json
            let (slot, display) = try await (slotResult, displayResult)
            if let display { self.display = display }
            apply(slot)
            loadError = nil
            schedulePreview(immediately: true)
        } catch {
            loadError = APIError.from(error)
        }
    }

    private func apply(_ slot: Slot) {
        original = slot
        let loaded = SlotDraft(slot.content)
        originalDraft = loaded
        draft = loaded
        hasConflict = false
        saveError = nil
        calendarCheck = .idle
    }

    // MARK: Live-Vorschau

    /// Ein Textfeld überschreitet das Vertragslimit: kein `POST …/preview` (Backend antwortet 422),
    /// die zuletzt gültige Vorschau bleibt gedimmt stehen.
    public var isPreviewBlockedByLength: Bool {
        draft.kind == .text && !draft.text.tooLongFields.isEmpty
    }

    public static let previewAfterShorteningHint = "Vorschau nach dem Kürzen"

    /// Nach jeder Änderung aufrufen; rendert nach 600 ms Ruhe (`POST …/preview`).
    public func schedulePreview(immediately: Bool = false) {
        previewTask?.cancel()
        guard let content = draft.content, !isReadOnly || immediately else { return }
        previewTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: Self.previewDebounce)
            }
            guard !Task.isCancelled else { return }
            await self?.renderPreview(content)
        }
    }

    private func renderPreview(_ content: SlotContent) async {
        isRenderingPreview = true
        defer { isRenderingPreview = false }
        do {
            let output = try await client.renderSlotPreview(
                path: .init(displayId: displayId, slot: slotNumber),
                body: .json(content)
            )
            let body = try expect(output) { try $0.ok.body.png }
            let data = try await Data(collecting: body, upTo: 4 * 1024 * 1024)
            guard !Task.isCancelled else { return }
            previewPNG = data
            previewError = nil
        } catch {
            guard !Task.isCancelled else { return }
            let apiError = APIError.from(error)
            guard apiError.code != "cancelled" else { return }
            previewError = Self.previewErrorText(apiError)
        }
    }

    /// 422 mit `fields.<feld>`: Hinweis zum betroffenen Feld statt allgemeinem Vorschaufehler.
    static func previewErrorText(_ error: APIError) -> String {
        guard error.statusCode == 422, !error.fields.isEmpty else { return error.message }
        return error.fields.sorted { $0.key < $1.key }.map { key, messages in
            let name = fieldLabel(key)
            return messages.isEmpty ? "\(name): ungültig." : "\(name): \(messages.joined(separator: " "))"
        }.joined(separator: "\n")
    }

    /// `content.headline`, `headline` → „Überschrift“; Unbekanntes bleibt wie geliefert.
    static func fieldLabel(_ key: String) -> String {
        switch key.split(separator: ".").last.map(String.init) ?? key {
        case "title": "Titel"
        case "headline": "Überschrift"
        case "subHeadline": "Unterüberschrift"
        case "message": "Nachricht"
        default: key
        }
    }

    // MARK: Speichern

    /// Speichert mit `If-Match`; `overwrite` ignoriert eine zwischenzeitliche Änderung (nach 412).
    /// Liefert die gespeicherte Ansicht oder `nil` bei Fehler bzw. Konflikt.
    @discardableResult
    public func save(overwrite: Bool = false) async -> Slot? {
        guard let content = draft.content, let original else { return nil }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let output = try await client.updateSlot(
                path: .init(displayId: displayId, slot: slotNumber),
                headers: .init(ifMatch: overwrite ? nil : original.etag),
                body: .json(content)
            )
            if case .preconditionFailed = output {
                hasConflict = true
                return nil
            }
            let saved = try expect(output) { try $0.ok.body.json }
            apply(saved)
            return saved
        } catch {
            saveError = APIError.from(error)
            return nil
        }
    }

    /// Nach 412: gespeicherten Stand laden und den Entwurf verwerfen.
    public func reloadDiscardingChanges() async {
        hasConflict = false
        await load()
    }

    public func dismissConflict() { hasConflict = false }

    // MARK: Bild

    /// Bereitet die Bilddaten vor (HEIC → JPEG, ≤ 2400 px, ≤ mediaMaxBytes) und lädt sie hoch.
    public func uploadImage(_ data: Data) async {
        isUploading = true
        uploadError = nil
        defer { isUploading = false }
        do {
            let maxBytes = system?.raw.mediaMaxBytes ?? 5_000_000
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ImagePreparation.prepare(data, maxBytes: maxBytes)
            }.value
            let media = try await MediaUploader.upload(prepared, client: client)
            draft.image.mediaId = media.id
            schedulePreview(immediately: true)
        } catch let failure as ImagePreparation.Failure {
            uploadError = failure.errorDescription
        } catch {
            uploadError = APIError.from(error).message
        }
    }

    /// Bild aus der Bibliothek übernehmen – kein erneuter Upload.
    public func selectMedia(_ mediaId: String) {
        uploadError = nil
        draft.image.mediaId = mediaId
        schedulePreview(immediately: true)
    }

    // MARK: Kalender

    public func checkCalendar() async {
        let url = SlotDraft.Calendar.normalizedURL(draft.calendar.url)
        guard draft.calendar.isValidURL else {
            calendarCheck = .failed("Bitte eine gültige Kalender-URL eingeben.")
            return
        }
        calendarCheck = .running
        do {
            let result = try expect(try await client.checkCalendarUrl(
                path: .init(displayId: displayId),
                body: .json(.init(url: url))
            )) { try $0.ok.body.json }
            calendarCheck = result.ok
                ? .ok(eventCount: result.eventCount)
                : .failed(result.error ?? "Der Kalender konnte nicht abgerufen werden.")
        } catch {
            calendarCheck = .failed(APIError.from(error).message)
        }
    }

    /// URL geändert → altes Prüfergebnis verwerfen.
    public func calendarURLChanged() { calendarCheck = .idle }
}
