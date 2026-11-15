import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bereitet Fotos für `POST /media` vor (ui-spec §4): HEIC und andere Formate → JPEG,
/// längste Kante höchstens 2400 px, Größe gegen `System.mediaMaxBytes`. PNG bleibt PNG,
/// wenn es klein genug ist (verlustfrei, wichtig für Grafiken mit wenigen Farben).
public enum ImagePreparation {
    public static let maxPixelSize = 2400

    public struct Prepared: Sendable, Equatable {
        public let data: Data
        public let mimeType: String
        public let fileExtension: String
        public let width: Int
        public let height: Int
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable
        case tooLarge(maxBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                L("Das Bild konnte nicht gelesen werden.")
            case .tooLarge(let maxBytes):
                L("Das Bild ist zu groß (höchstens \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file))).")
            }
        }
    }

    public static func prepare(_ input: Data, maxBytes: Int) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw Failure.unreadable }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let type = CGImageSourceGetType(source) as String?

        // Unverändert übernehmen: PNG/JPEG ohne Drehung, klein genug in Pixeln und Bytes.
        let passthrough: (String, String)? = switch type {
        case UTType.png.identifier: ("image/png", "png")
        case UTType.jpeg.identifier: ("image/jpeg", "jpg")
        default: nil
        }
        if let (mime, ext) = passthrough, orientation == 1,
           max(width, height) <= maxPixelSize, input.count <= maxBytes {
            return Prepared(data: input, mimeType: mime, fileExtension: ext, width: width, height: height)
        }

        // Skalieren (inkl. EXIF-Drehung) und als JPEG kodieren.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        for quality in [0.85, 0.7, 0.55, 0.4] {
            guard let data = encodeJPEG(image, quality: quality) else { throw Failure.unreadable }
            if data.count <= maxBytes {
                return Prepared(data: data, mimeType: "image/jpeg", fileExtension: "jpg",
                                width: image.width, height: image.height)
            }
        }
        throw Failure.tooLarge(maxBytes: maxBytes)
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
