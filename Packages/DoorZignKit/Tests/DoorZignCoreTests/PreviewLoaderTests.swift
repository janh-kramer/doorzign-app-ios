import DoorZignAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import DoorZignCore

/// Liefert die Vertrags-Fixture preview-ep400.png mit ETag bzw. 304 bei passendem If-None-Match.
private final class PreviewStubTransport: ClientTransport, @unchecked Sendable {
    let png: Data
    var etag = "\"v1\""
    private(set) var requests: [HTTPRequest] = []
    private(set) var lastStatus: HTTPResponse.Status?
    private let lock = NSLock()

    init(png: Data) { self.png = png }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { requests.append(request) }
        if request.headerFields[.ifNoneMatch] == etag {
            lock.withLock { lastStatus = .notModified }
            return (HTTPResponse(status: .notModified), nil)
        }
        lock.withLock { lastStatus = .ok }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/png"
        response.headerFields[.eTag] = etag
        return (response, HTTPBody(png))
    }

    var requestCount: Int { lock.withLock { requests.count } }
    var lastIfNoneMatch: String? { lock.withLock { requests.last?.headerFields[.ifNoneMatch] } }
}

@Suite struct PreviewLoaderTests {
    static func fixturePNG() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../../doorzign-app-coordination/contract/fixtures/preview-ep400.png")
            .standardizedFileURL
        return try Data(contentsOf: url)
    }

    @Test func etagCacheUnd304() async throws {
        let png = try Self.fixturePNG()
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let transport = PreviewStubTransport(png: png)
        // Gleiche Middleware-Kette wie in der App (ohne Auth).
        let client = Client(
            serverURL: URL(string: "https://example.invalid/mobile/v1")!,
            transport: transport,
            middlewares: [HeaderDecodingMiddleware()]
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let loader = PreviewLoader(client: client, cache: PreviewCache(directory: dir))

        // 1. Erstes Laden: Request ohne If-None-Match.
        #expect(await loader.preview(displayId: "d1", slot: 1, expectedEtag: "\"v1\"") == png)
        #expect(transport.requestCount == 1)
        #expect(transport.lastIfNoneMatch == nil)

        // 2. ETag aus Display.slots stimmt mit dem Cache überein → kein Request.
        #expect(await loader.preview(displayId: "d1", slot: 1, expectedEtag: "\"v1\"") == png)
        #expect(transport.requestCount == 1)

        // 3. ETag weicht ab → bedingter Request, Server antwortet 304 → Cache.
        #expect(await loader.preview(displayId: "d1", slot: 1, expectedEtag: "\"anders\"") == png)
        #expect(transport.requestCount == 2)
        #expect(transport.lastIfNoneMatch == "\"v1\"")  // roh, nicht %22v1%22
        #expect(transport.lastStatus == .notModified)

        // 4. Neue Version auf dem Server → 200 mit neuem ETag.
        transport.etag = "\"v2\""
        #expect(await loader.preview(displayId: "d1", slot: 1, expectedEtag: "\"v2\"") == png)
        #expect(transport.requestCount == 3)
        #expect(await loader.preview(displayId: "d1", slot: 1, expectedEtag: "\"v2\"") == png)
        #expect(transport.requestCount == 3)

        // 5. previewEtag null (Vertrag 1.2.3: preview.png wäre 404) → keine Anfrage, Cache verworfen.
        #expect(await loader.preview(displayId: "d1", slot: 1, expectedEtag: nil) == nil)
        #expect(transport.requestCount == 3)
        #expect(await PreviewCache(directory: dir).entry(for: PreviewLoader.key(displayId: "d1", slot: 1)) == nil)
    }
}

@Suite struct ETagNormalizationTests {
    @Test func toleranterVergleich() {
        #expect(ETag.matches("\"e1a\"", "e1a"))
        #expect(ETag.matches("W/\"e1a\"", "\"e1a\""))
        #expect(!ETag.matches("\"e1a\"", "\"e1b\""))
        #expect(!ETag.matches(nil, "e1a"))
    }
}
