import CoreGraphics
import DoorZignAPI
import Foundation
import ImageIO
import Observation
import OpenAPIRuntime
import UniformTypeIdentifiers

/// Bildbibliothek (`GET /media`, nur mit Feature `media.library`). Auswahl setzt `mediaId` ohne neuen Upload.
@MainActor
@Observable
public final class MediaLibraryModel {
    public private(set) var items: [Media] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var error: APIError?

    @ObservationIgnored public let thumbnails: MediaThumbnailLoader
    @ObservationIgnored private let client: Client

    public init(client: Client) {
        self.client = client
        self.thumbnails = MediaThumbnailLoader(client: client)
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try expect(try await client.listMedia()) { try $0.ok.body.json.data }
            hasLoaded = true
            error = nil
        } catch {
            let apiError = APIError.from(error)
            if apiError.code != "cancelled" { self.error = apiError }
        }
    }
}

/// Lädt Originalbilder über `GET /media/{id}` (mit Bearer über den Client) und verkleinert sie zu Miniaturen.
/// Hält die Miniaturen im Speicher; gleichzeitige Anfragen für dasselbe Bild werden zusammengefasst.
public actor MediaThumbnailLoader {
    /// Kantenlänge der Miniaturen in Pixeln (Raster mit ~110 pt bei @3x).
    public static let maxPixelSize = 360
    /// Obergrenze für das geladene Original (Edge erlaubt Uploads bis 20 MB).
    public static let maxOriginalBytes = 25 * 1024 * 1024

    private let client: Client
    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(client: Client) {
        self.client = client
    }

    /// JPEG-Miniatur oder `nil`, wenn das Bild nicht geladen werden kann.
    public func thumbnail(for mediaId: String) async -> Data? {
        if let cached = cache[mediaId] { return cached }
        if let task = inFlight[mediaId] { return await task.value }
        let client = client
        let task = Task<Data?, Never> {
            guard let output = try? await client.getMedia(path: .init(mediaId: mediaId)),
                  case .ok(let ok) = output,
                  let original = try? await Data(collecting: ok.body.image_Ast_, upTo: Self.maxOriginalBytes)
            else { return nil }
            return Self.downsample(original, maxPixelSize: Self.maxPixelSize)
        }
        inFlight[mediaId] = task
        let result = await task.value
        inFlight[mediaId] = nil
        if let result { cache[mediaId] = result }
        return result
    }

    /// Verkleinert beliebige Bilddaten (PNG/JPEG/WebP) auf `maxPixelSize` und kodiert als JPEG.
    public static func downsample(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return ImagePreparation.encode(image, type: .jpeg, quality: 0.8)
    }
}
