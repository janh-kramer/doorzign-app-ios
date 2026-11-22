import CoreGraphics
import DoorZignAPI
import Foundation
import HTTPTypes
import ImageIO
import OpenAPIRuntime
import Testing
import UniformTypeIdentifiers
@testable import DoorZignCore

/// Stub-Transport, der pro Operation eine Antwort liefert und die Requests (inkl. Body) mitschreibt.
final class RoutingStubTransport: ClientTransport, @unchecked Sendable {
    struct Recorded { let operationID: String; let request: HTTPRequest; let body: Data }
    typealias Handler = @Sendable (HTTPRequest, Data) -> (HTTPResponse, Data?)

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private(set) var recorded: [Recorded] = []

    func on(_ operationID: String, _ handler: @escaping Handler) { lock.withLock { handlers[operationID] = handler } }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var data = Data()
        if let body { data = try await Data(collecting: body, upTo: 50_000_000) }
        let handler = lock.withLock { () -> Handler? in
            recorded.append(Recorded(operationID: operationID, request: request, body: data))
            return handlers[operationID]
        }
        guard let handler else { return (HTTPResponse(status: .notFound), nil) }
        let (response, responseBody) = handler(request, data)
        return (response, responseBody.map { HTTPBody($0) })
    }

    func requests(_ operationID: String) -> [Recorded] { lock.withLock { recorded.filter { $0.operationID == operationID } } }

    static func json(_ status: HTTPResponse.Status, _ object: Any) -> (HTTPResponse, Data?) {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, try! JSONSerialization.data(withJSONObject: object))
    }

    func makeClient() -> Client {
        Client(serverURL: URL(string: "https://example.invalid/mobile/v1")!,
               configuration: Configuration(dateTranscoder: LenientDateTranscoder()),
               transport: self, middlewares: [HeaderDecodingMiddleware()])
    }
}

@Suite struct SlotDraftTests {
    @Test func standardfarbenUndRoundtrip() throws {
        let draft = SlotDraft(kind: .text)
        #expect(draft.text.color == .black && draft.text.bg == .white)
        #expect(draft.text.messageColor == .white && draft.text.messageBg == .black)
        let content = try #require(draft.content)
        #expect(SlotDraft(content) == draft)
    }

    @Test func zuLangerTextIstUnvollstaendig() {
        var draft = SlotDraft(kind: .text)
        draft.text.title = String(repeating: "x", count: 51)
        #expect(draft.content == nil)
        #expect(draft.incompleteReason != nil)
    }

    @Test func kalenderURL() throws {
        var draft = SlotDraft(kind: .calendar)
        draft.calendar.url = " webcal://example.org/cal.ics "
        guard case .calendar(let c)? = draft.content else { Issue.record("kein Kalender"); return }
        #expect(c.url == "https://example.org/cal.ics")
        draft.calendar.url = "kein link"
        #expect(draft.content == nil)
        draft.calendar.source = .zeitwart
        #expect(draft.incompleteReason == "Wird in Zeitwart konfiguriert.")
    }

    @Test func bildOhneMedium() {
        #expect(SlotDraft(kind: .image).content == nil)
    }
}

@Suite struct ImagePreparationTests {
    static func makePNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Rauschen, damit die Kompression nicht trivial ist.
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(red: CGFloat((x * 7 + y * 3) % 255) / 255, green: CGFloat((x ^ y) % 255) / 255, blue: 0.5, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func kleinesPNGBleibtUnveraendert() throws {
        let png = try PreviewLoaderTests.fixturePNG()
        let prepared = try ImagePreparation.prepare(png, maxBytes: 5_000_000)
        #expect(prepared.data == png)
        #expect(prepared.mimeType == "image/png")
        #expect(prepared.width == 400 && prepared.height == 300)
    }

    @Test func grossesPNGWirdSkaliertUndBleibtPNG() throws {
        let png = try Self.makePNG(width: 4000, height: 3000)
        let prepared = try ImagePreparation.prepare(png, maxBytes: 5_000_000)
        #expect(prepared.mimeType == "image/png")
        #expect(max(prepared.width, prepared.height) == 2400)
        #expect(prepared.data.count <= 5_000_000)
    }

    @Test func pngZuGrossAlsPNGWirdJPEG() throws {
        // Fotoähnlich (Verlauf mit leichtem Rauschen): als PNG groß, als JPEG klein.
        let (width, height) = (1200, 900)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 1
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Int(seed >> 28)  // 0…15
            let i = (y * width + x) * 4
            pixels[i] = UInt8(x * 200 / width + noise); pixels[i + 1] = UInt8(y * 200 / height + noise); pixels[i + 2] = 128
        } }
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let png = try #require(ImagePreparation.encode(image, type: .png, quality: nil))
        let rotatedPNG = try ImagePreparation.prepare(png, quarterTurns: 1, maxBytes: .max)
        #expect(rotatedPNG.mimeType == "image/png")
        let prepared = try ImagePreparation.prepare(png, quarterTurns: 1, maxBytes: rotatedPNG.data.count - 1)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.width == 900 && prepared.height == 1200)
    }

    // MARK: Bild drehen (decisions 44)

    /// Gespeichert quer: linke Hälfte rot, rechte blau. Optional mit EXIF-Orientation.
    static func makeHalves(width: Int, height: Int, type: UTType, orientation: UInt32? = nil) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Farbe (r, g, b) am Bildpunkt (x, y), y von oben.
    static func pixel(_ data: Data, x: Int, y: Int) throws -> (Int, Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (Int(buffer[i]), Int(buffer[i + 1]), Int(buffer[i + 2]))
    }

    static func isRed(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 60 && c.2 < 60 }
    static func isBlue(_ c: (Int, Int, Int)) -> Bool { c.0 < 60 && c.1 < 60 && c.2 > 200 }

    static func orientation(_ data: Data) throws -> UInt32? {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyOrientation] as? UInt32
    }

    @Test func hochformatMitExif6KommtOhneDrehungAufrechtAn() throws {
        // Gespeichert 80×40, EXIF 6 (90° im Uhrzeigersinn anzeigen) → aufrecht 40×80, oben rot, unten blau.
        let jpeg = try Self.makeHalves(width: 80, height: 40, type: .jpeg, orientation: 6)
        #expect(try Self.orientation(jpeg) == 6)
        let prepared = try ImagePreparation.prepare(jpeg, maxBytes: 5_000_000)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.width == 40 && prepared.height == 80)
        #expect([nil, 1].contains(try Self.orientation(prepared.data)))
        #expect(Self.isRed(try Self.pixel(prepared.data, x: 20, y: 10)))
        #expect(Self.isBlue(try Self.pixel(prepared.data, x: 20, y: 70)))
    }

    @Test func einmalRechtsTauschtBreiteUndHoehe() throws {
        // 80×40, links rot → im Uhrzeigersinn gedreht 40×80, rot oben.
        let jpeg = try Self.makeHalves(width: 80, height: 40, type: .jpeg)
        let prepared = try ImagePreparation.prepare(jpeg, quarterTurns: 1, maxBytes: 5_000_000)
        #expect(prepared.width == 40 && prepared.height == 80)
        #expect(Self.isRed(try Self.pixel(prepared.data, x: 20, y: 10)))
        #expect(Self.isBlue(try Self.pixel(prepared.data, x: 20, y: 70)))
    }

    @Test func einmalLinksDrehtGegenDenUhrzeigersinn() throws {
        // links rot → gegen den Uhrzeigersinn gedreht: rot unten.
        let jpeg = try Self.makeHalves(width: 80, height: 40, type: .jpeg)
        let prepared = try ImagePreparation.prepare(jpeg, quarterTurns: -1, maxBytes: 5_000_000)
        #expect(prepared.width == 40 && prepared.height == 80)
        #expect(Self.isBlue(try Self.pixel(prepared.data, x: 20, y: 10)))
        #expect(Self.isRed(try Self.pixel(prepared.data, x: 20, y: 70)))
    }

    @Test func exif6UndRechtsDrehenAddierenSich() throws {
        // EXIF 6 aufrecht (rot oben), dann 1× rechts → 80×40, rot rechts.
        let jpeg = try Self.makeHalves(width: 80, height: 40, type: .jpeg, orientation: 6)
        let prepared = try ImagePreparation.prepare(jpeg, quarterTurns: 1, maxBytes: 5_000_000)
        #expect(prepared.width == 80 && prepared.height == 40)
        #expect(Self.isBlue(try Self.pixel(prepared.data, x: 10, y: 20)))
        #expect(Self.isRed(try Self.pixel(prepared.data, x: 70, y: 20)))
    }

    @Test func vierDrehungenSindKeine() throws {
        let png = try Self.makeHalves(width: 80, height: 40, type: .png)
        #expect(try ImagePreparation.prepare(png, quarterTurns: 4, maxBytes: 5_000_000).data == png)
    }

    @Test func jpegOhneDrehungWirdTrotzdemNeuKodiert() throws {
        let jpeg = try Self.makeHalves(width: 80, height: 40, type: .jpeg)
        let prepared = try ImagePreparation.prepare(jpeg, maxBytes: 5_000_000)
        #expect(prepared.data != jpeg)
        #expect(prepared.mimeType == "image/jpeg")
        #expect([nil, 1].contains(try Self.orientation(prepared.data)))
    }

    @Test func gedrehtesPNGBleibtPNG() throws {
        let png = try Self.makeHalves(width: 80, height: 40, type: .png)
        let prepared = try ImagePreparation.prepare(png, quarterTurns: 1, maxBytes: 5_000_000)
        #expect(prepared.mimeType == "image/png" && prepared.fileExtension == "png")
        #expect(prepared.data != png)
        #expect(prepared.width == 40 && prepared.height == 80)
        #expect(Self.isRed(try Self.pixel(prepared.data, x: 20, y: 10)))
    }

    @Test func zuGrossFuerLimit() throws {
        let png = try Self.makePNG(width: 3000, height: 3000)
        #expect(throws: ImagePreparation.Failure.tooLarge(maxBytes: 1000)) {
            try ImagePreparation.prepare(png, maxBytes: 1000)
        }
    }

    @Test func keinBild() {
        #expect(throws: ImagePreparation.Failure.unreadable) { try ImagePreparation.prepare(Data("hallo".utf8), maxBytes: 1000) }
    }
}

@Suite struct MediaUploadTests {
    @Test func multipartMitBildContentType() async throws {
        let transport = RoutingStubTransport()
        transport.on("uploadMedia") { _, _ in
            RoutingStubTransport.json(.created, ["id": "m-1", "mime": "image/png", "width": 400, "height": 300])
        }
        let png = try PreviewLoaderTests.fixturePNG()
        let prepared = try ImagePreparation.prepare(png, maxBytes: 5_000_000)
        let media = try await MediaUploader.upload(prepared, client: transport.makeClient())
        #expect(media.id == "m-1")

        let request = try #require(transport.requests("uploadMedia").first)
        #expect(request.request.headerFields[.contentType]?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains(#"content-disposition: form-data; name="file"; filename="bild.png""#))
        #expect(body.contains("content-type: image/png"))
        #expect(!body.contains("text/plain"))
        // Die PNG-Bytes stecken unverändert im Body.
        #expect(request.body.range(of: png) != nil)
    }
}

@Suite @MainActor struct SlotEditorTests {
    static let slotJSON: [String: Any] = [
        "slot": 2, "editable": true, "transferred": true, "etag": "\"c2\"",
        "content": ["type": "text", "title": "Alt", "headline": "", "subHeadline": "", "message": "",
                    "color": "black", "bg": "white", "messageColor": "white", "messageBg": "black"],
    ]

    static func makeTransport() -> RoutingStubTransport {
        let transport = RoutingStubTransport()
        transport.on("getSlot") { _, _ in RoutingStubTransport.json(.ok, slotJSON) }
        transport.on("getDisplay") { _, _ in (HTTPResponse(status: .notFound), nil) }
        transport.on("renderSlotPreview") { _, _ in
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "image/png"
            return (response, try! PreviewLoaderTests.fixturePNG())
        }
        return transport
    }

    @Test func speichernMitIfMatchUnd412() async throws {
        let transport = Self.makeTransport()
        // Erst Konflikt, beim Überschreiben (ohne If-Match) Erfolg.
        transport.on("updateSlot") { request, body in
            if request.headerFields[.ifMatch] != nil {
                return RoutingStubTransport.json(.preconditionFailed, ["error": ["code": "conflict", "message": "Geändert"]])
            }
            var saved = SlotEditorTests.slotJSON
            saved["content"] = try! JSONSerialization.jsonObject(with: body)
            saved["etag"] = "\"c3\""
            return RoutingStubTransport.json(.ok, saved)
        }
        let model = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(), system: nil)
        await model.load()
        #expect(model.loadError == nil)
        #expect(!model.isDirty)
        #expect(!model.isReadOnly)

        model.draft.text.title = "Neu"
        #expect(model.isDirty && model.canSave)

        #expect(await model.save() == nil)
        #expect(model.hasConflict)
        let first = try #require(transport.requests("updateSlot").first)
        #expect(first.request.headerFields[.ifMatch] == "\"c2\"")  // roh, nicht %22c2%22

        let saved = try #require(await model.save(overwrite: true))
        #expect(saved.etag == "\"c3\"")
        #expect(!model.hasConflict && !model.isDirty)
        #expect(model.draft.text.title == "Neu")
    }

    @Test func vorschauMitDebounce() async throws {
        let transport = Self.makeTransport()
        let model = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(), system: nil)
        await model.load()
        try await Task.sleep(for: .milliseconds(100))
        let afterLoad = transport.requests("renderSlotPreview").count
        #expect(afterLoad == 1)

        // Mehrere schnelle Änderungen → genau ein Render nach der Wartezeit.
        for title in ["A", "AB", "ABC"] {
            model.draft.text.title = title
            model.schedulePreview()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(transport.requests("renderSlotPreview").count == afterLoad)
        try await Task.sleep(for: .milliseconds(800))
        #expect(transport.requests("renderSlotPreview").count == afterLoad + 1)
        #expect(model.previewPNG != nil)
        let lastBody = try #require(transport.requests("renderSlotPreview").last?.body)
        #expect(String(decoding: lastBody, as: UTF8.self).contains("\"ABC\""))
    }

    @Test func aktiveAnsichtNichtDeaktivierbar() async throws {
        let transport = Self.makeTransport()
        let model = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(), system: nil)
        await model.load()
        // Ohne Display-Info gilt die Ansicht nicht als aktiv.
        #expect(model.isKindEnabled(.deactivated))
        #expect(!model.isKindEnabled(.calendar))  // nicht Ansicht 1, keine Lizenz/Feature
    }
}

/// Vertragskonvention (1.2.1): Optionale Felder ohne Wert werden weggelassen, TextContent trägt immer `type: text`.
@Suite struct EncodingConventionTests {
    @Test func nilFelderFehlenUndTypIstGesetzt() throws {
        let content = Components.Schemas.TextContent(_type: .text, headline: "Hallo")
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
        #expect(json["type"] as? String == "text")
        #expect(json["headline"] as? String == "Hallo")
        #expect(json.keys.sorted() == ["headline", "type"])

        var draft = SlotDraft(kind: .calendar)
        draft.calendar.url = "https://example.org/k.ics"
        let calendar = try #require(draft.content)
        let calendarJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(calendar)) as? [String: Any])
        #expect(calendarJSON["timezone"] == nil)  // nicht gesetzt → weggelassen, nicht null
        #expect(calendarJSON["view"] == nil)
    }
}

/// Edge-Web erlaubt längere Texte (title 120, headline 160, …) als der Vertrag (50/75/50/100).
@Suite struct OverlongTextTests {
    @Test func ueberlangeTexteAnnehmenUndBeimSpeichernHinweisen() async throws {
        var fixture = try #require(contractFixture("slots.json") as? [String: Any])
        var slots = try #require(fixture["data"] as? [[String: Any]])
        let index = try #require(slots.firstIndex { ($0["content"] as? [String: Any])?["type"] as? String == "text" })
        var content = try #require(slots[index]["content"] as? [String: Any])
        content["title"] = String(repeating: "T", count: 120)
        content["headline"] = String(repeating: "H", count: 160)
        content["message"] = String(repeating: "M", count: 200)
        slots[index]["content"] = content
        fixture["data"] = slots
        let response = fixture

        let transport = RoutingStubTransport()
        transport.on("listSlots") { _, _ in RoutingStubTransport.json(.ok, response) }
        // Kein Decode-Fehler trotz Überschreitung von maxLength.
        let decoded = try await transport.makeClient().listSlots(path: .init(displayId: "d-1")).ok.body.json.data
        let slot = try #require(decoded.first { if case .text = $0.content { true } else { false } })
        guard case .text(let text) = slot.content else { Issue.record("erwartet: Text"); return }
        #expect(text.headline?.count == 160)

        // Entwurf übernimmt die Texte vollständig, Speichern ist gesperrt mit konkretem Hinweis.
        let draft = SlotDraft(slot.content)
        #expect(draft.text.headline.count == 160)
        #expect(draft.content == nil)
        #expect(draft.text.tooLongFields.map { $0.name } == ["Titel", "Überschrift", "Nachricht"])
        let reason = try #require(draft.incompleteReason)
        #expect(reason.contains("Überschrift (160/75)"))
    }

    @Test func eingabebegrenzungSchneidetVorhandenesNichtAb() {
        let long = String(repeating: "x", count: 160)
        // Normales Tippen über das Limit wird abgeschnitten.
        #expect(SlotDraft.Text.limitedInput("abcdef", previous: "abcde", limit: 5) == "abcde")
        // Zu langer Bestand: ein weiteres Zeichen wird abgelehnt, nicht auf 75 gekürzt.
        #expect(SlotDraft.Text.limitedInput(long + "y", previous: long, limit: 75) == long)
        // Kürzen ist erlaubt.
        #expect(SlotDraft.Text.limitedInput(String(long.dropLast(10)), previous: long, limit: 75).count == 150)
    }
}

/// Vorschau bei Überlänge: kein Request, letzte gültige Vorschau bleibt; 422 → Feldhinweis.
@Suite @MainActor struct OverlongPreviewTests {
    @Test func keinPreviewRequestBeiUeberlaenge() async throws {
        let transport = SlotEditorTests.makeTransport()
        let model = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(), system: nil)
        await model.load()
        try await Task.sleep(for: .milliseconds(100))
        let afterLoad = transport.requests("renderSlotPreview").count
        let lastValid = try #require(model.previewPNG)

        model.draft.text.headline = String(repeating: "H", count: 160)
        model.schedulePreview(immediately: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isPreviewBlockedByLength)
        #expect(transport.requests("renderSlotPreview").count == afterLoad)
        #expect(model.previewPNG == lastValid)

        // Nach dem Kürzen wird wieder gerendert.
        model.draft.text.headline = "Kurz"
        model.schedulePreview(immediately: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.isPreviewBlockedByLength)
        #expect(transport.requests("renderSlotPreview").count == afterLoad + 1)
    }

    @Test func fehler422ZeigtFeldhinweis() async throws {
        let transport = SlotEditorTests.makeTransport()
        transport.on("renderSlotPreview") { _, _ in
            RoutingStubTransport.json(.unprocessableContent, ["error": [
                "code": "validation_failed", "message": "Ungültige Eingabe",
                "fields": ["content.headline": ["Höchstens 75 Zeichen."]],
            ]])
        }
        let model = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(), system: nil)
        await model.load()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.previewError == "Überschrift: Höchstens 75 Zeichen.")
    }
}

/// Vertrag 1.2.4: Kalender ohne Lizenz → 403 `unlicensed` (PUT iCal und calendar/check).
@Suite @MainActor struct CalendarUnlicensedTests {
    static let unlicensed: [String: Any] = ["error": ["code": "unlicensed", "message": "Keine Berechtigung"]]

    @Test func lizenzfehlerStattKeineBerechtigung() async throws {
        let transport = SlotEditorTests.makeTransport()
        transport.on("updateSlot") { _, _ in RoutingStubTransport.json(.forbidden, Self.unlicensed) }
        transport.on("checkCalendarUrl") { _, _ in RoutingStubTransport.json(.forbidden, Self.unlicensed) }
        let model = SlotEditorModel(displayId: "d-1", slot: 1, display: nil, client: transport.makeClient(), system: nil)
        await model.load()
        model.draft.kind = .calendar
        model.draft.calendar.url = "https://example.org/k.ics"

        await model.checkCalendar()
        #expect(model.calendarCheck == .failed(APIError.calendarUnlicensedMessage))

        #expect(await model.save() == nil)
        #expect(model.saveError?.code == "unlicensed")
        #expect(model.saveError?.message == APIError.calendarUnlicensedMessage)
    }

    @Test func allgemeinerLizenzfehler() throws {
        let data = try JSONSerialization.data(withJSONObject: Self.unlicensed)
        let response = try JSONDecoder().decode(Components.Schemas.ErrorResponse.self, from: data)
        #expect(APIError(response, statusCode: 403).message == APIError.unlicensedMessage)
        #expect(SlotEditorModel.fieldLabel("content.source") == "Quelle")
    }
}

/// decisions 47: Vorschauen flächenmittelnd verkleinern.
@Suite struct PreviewScalingTests {
    /// 1-Pixel-Schachbrett Schwarz/Weiß als PNG.
    static func checkerboard(width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width where (x + y) % 2 == 0 {
            let i = (y * width + x) * 4
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
        } }
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        return try #require(ImagePreparation.encode(image, type: .png, quality: nil))
    }

    static func grayRange(_ image: CGImage) throws -> ClosedRange<Int> {
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var low = 255, high = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for c in 0..<3 { low = min(low, Int(pixels[i + c])); high = max(high, Int(pixels[i + c])) }
        }
        return low...high
    }

    @Test func schachbrettAufEinViertelWirdGrau() throws {
        let png = try Self.checkerboard(width: 800, height: 480)
        let image = try #require(PreviewScaling.downscaled(png, to: CGSize(width: 200, height: 120)))
        #expect(image.width == 200 && image.height == 120)
        let range = try Self.grayRange(image)
        // ≈ 50 % Grau überall, kein Schwarz/Weiß-Muster (Nearest-Neighbor ergäbe 0…255).
        #expect(range.lowerBound >= 110 && range.upperBound <= 145, "Bereich \(range)")
    }

    @Test func schachbrettKrummerFaktorBleibtGrau() throws {
        let png = try Self.checkerboard(width: 800, height: 480)
        let image = try #require(PreviewScaling.downscaled(png, to: CGSize(width: 137, height: 82)))
        let range = try Self.grayRange(image)
        #expect(range.lowerBound >= 90 && range.upperBound <= 165, "Bereich \(range)")
    }

    @Test func zielgroesseNurBeimVerkleinern() throws {
        let png = try Self.checkerboard(width: 800, height: 480)
        let size = try #require(PreviewScaling.pixelSize(of: png))
        #expect(size == CGSize(width: 800, height: 480))
        // Miniatur 64×64 pt @3x: passt auf 192 px Breite → 192×115.
        #expect(PreviewScaling.targetPixelSize(image: size, frame: CGSize(width: 64, height: 64), displayScale: 3)
                == CGSize(width: 192, height: 115))
        // Groß genug dargestellt (Editor, Vergrößerung): nicht verkleinern → pixelgenau mit Nearest-Neighbor.
        #expect(PreviewScaling.targetPixelSize(image: size, frame: CGSize(width: 400, height: 240), displayScale: 3) == nil)
        #expect(PreviewScaling.targetPixelSize(image: size, frame: CGSize(width: 800, height: 480), displayScale: 1) == nil)
    }
}
