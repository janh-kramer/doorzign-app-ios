import ImageIO
import DoorZignAPI
import Foundation
import HTTPTypes
import Testing
@testable import DoorZignCore

func makeSystem(features: [String]) throws -> SystemInfo {
    let json: [String: Any] = [
        "systemType": "edge", "instanceId": "i-1", "name": "Test", "apiVersion": "1.2.2",
        "minAppVersion": "1.0.0", "features": features, "timezone": "Europe/Berlin", "mediaMaxBytes": 20_000_000,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return SystemInfo(try JSONDecoder().decode(Components.Schemas.System.self, from: data))
}

@Suite @MainActor struct MediaLibraryTests {
    static func makeTransport() throws -> RoutingStubTransport {
        let transport = RoutingStubTransport()
        transport.on("listMedia") { _, _ in
            RoutingStubTransport.json(.ok, ["data": [
                ["id": "m-1", "mime": "image/jpeg", "width": 1200, "height": 800, "fileName": "Foyer.jpg"],
                ["id": "m-2", "mime": "image/png", "width": 400, "height": 300],
            ]])
        }
        let png = try ImagePreparationTests.makePNG(width: 1200, height: 800)
        transport.on("getMedia") { request, _ in
            guard request.path?.hasSuffix("/media/m-1") == true else { return (HTTPResponse(status: .notFound), nil) }
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "image/jpeg"  // konkreter Typ zu image/* im Vertrag
            return (response, png)
        }
        return transport
    }

    @Test func listeUndMiniaturen() async throws {
        let transport = try Self.makeTransport()
        let model = MediaLibraryModel(client: transport.makeClient())
        await model.load()
        #expect(model.error == nil)
        #expect(model.items.map(\.id) == ["m-1", "m-2"])
        #expect(model.items[0].fileName == "Foyer.jpg")

        // Gleichzeitige Anfragen → ein Request; danach aus dem Cache.
        async let a = model.thumbnails.thumbnail(for: "m-1")
        async let b = model.thumbnails.thumbnail(for: "m-1")
        let (first, second) = await (a, b)
        let thumb = try #require(first)
        #expect(second == thumb)
        #expect(await model.thumbnails.thumbnail(for: "m-1") == thumb)
        #expect(transport.requests("getMedia").count == 1)

        let source = try #require(CGImageSourceCreateWithData(thumb as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == MediaThumbnailLoader.maxPixelSize)

        #expect(await model.thumbnails.thumbnail(for: "m-2") == nil)  // 404
    }

    @Test func fehlendeBerechtigung() async throws {
        let transport = RoutingStubTransport()
        transport.on("listMedia") { _, _ in
            RoutingStubTransport.json(.forbidden, ["error": ["code": "forbidden", "message": "Keine Berechtigung"]])
        }
        let model = MediaLibraryModel(client: transport.makeClient())
        await model.load()
        #expect(model.error?.code == "forbidden")
        #expect(!model.hasLoaded)
    }

    @Test func auswahlImEditor() async throws {
        let transport = SlotEditorTests.makeTransport()
        let library = try makeSystem(features: ["media.library"])
        let model = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(), system: library)
        await model.load()
        #expect(model.canUseMediaLibrary && !model.canUploadImage)
        #expect(model.availableKinds.contains(.image) && model.isKindEnabled(.image))
        model.draft.kind = .image
        model.selectMedia("m-1")
        #expect(model.draft.content == .image(.init(_type: .image, mediaId: "m-1", fit: .crop, background: .white, dither: true)))
        #expect(model.canSave)
        #expect(transport.requests("uploadMedia").isEmpty)

        let none = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(),
                                   system: try makeSystem(features: []))
        await none.load()
        #expect(!none.availableKinds.contains(.image))
    }

    @Test func bildDrehenAbbrechenSchicktNichts() async throws {
        let transport = SlotEditorTests.makeTransport()
        let model = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(),
                                    system: try makeSystem(features: ["media.upload"]))
        await model.load()
        model.chooseImage(try ImagePreparationTests.makeHalves(width: 80, height: 40, type: .jpeg))
        #expect(model.pendingImage != nil)
        model.cancelPendingImage()
        #expect(model.pendingImage == nil)
        await model.uploadPendingImage(quarterTurns: 1)  // nichts mehr offen → kein Request
        #expect(transport.requests("uploadMedia").isEmpty)
        #expect(model.draft.image.mediaId == nil)
    }

    @Test func bildDrehenHochladenSchicktGedrehtesBild() async throws {
        let transport = SlotEditorTests.makeTransport()
        transport.on("uploadMedia") { _, _ in
            RoutingStubTransport.json(.created, ["id": "m-9", "mime": "image/jpeg", "width": 40, "height": 80])
        }
        let model = SlotEditorModel(displayId: "d-1", slot: 2, display: nil, client: transport.makeClient(),
                                    system: try makeSystem(features: ["media.upload"]))
        await model.load()
        model.chooseImage(try ImagePreparationTests.makeHalves(width: 80, height: 40, type: .jpeg))
        #expect(transport.requests("uploadMedia").isEmpty)  // erst nach „Hochladen“
        await model.uploadPendingImage(quarterTurns: 1)
        #expect(model.pendingImage == nil && model.uploadError == nil)
        #expect(model.draft.image.mediaId == "m-9")
        let body = try #require(transport.requests("uploadMedia").first).body
        // JPEG im Multipart-Body suchen (SOI … EOI) und Maße prüfen.
        let start = try #require(body.firstRange(of: Data([0xFF, 0xD8, 0xFF]))).lowerBound
        let end = try #require(body.lastRange(of: Data([0xFF, 0xD9]))).upperBound
        let source = try #require(CGImageSourceCreateWithData(body[start..<end] as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 80)
    }
}
