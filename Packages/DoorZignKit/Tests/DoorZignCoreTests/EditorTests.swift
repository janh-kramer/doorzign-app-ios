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

    @Test func grossesBildWirdSkaliertUndJPEG() throws {
        let png = try Self.makePNG(width: 4000, height: 3000)
        let prepared = try ImagePreparation.prepare(png, maxBytes: 5_000_000)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(max(prepared.width, prepared.height) == 2400)
        #expect(prepared.data.count <= 5_000_000)
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
