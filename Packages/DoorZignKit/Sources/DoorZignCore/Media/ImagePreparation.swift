import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bereitet Fotos für `POST /media` vor (ui-spec §4, decisions 44): EXIF-Ausrichtung anwenden, die Drehung des
/// Nutzers (Schritt „Bild drehen“) in die Pixel schreiben, längste Kante höchstens 2400 px, Größe gegen
/// `System.mediaMaxBytes`. JPEG/HEIC/WebP & Co. werden immer neu als JPEG ohne Orientation-Tag kodiert (Edge und
/// Zeitwart werten EXIF nicht aus). PNG bleibt PNG (verlustfrei, wichtig für Grafiken mit wenigen Farben); nur ein
/// ungedrehtes PNG, das in Pixeln und Bytes passt, geht unverändert hoch. Passt ein neu kodiertes PNG nicht in
/// `maxBytes`, wird es wie bisher als JPEG geschickt.
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

    /// - Parameter quarterTurns: Drehung des Nutzers in 90°-Schritten im Uhrzeigersinn (negativ = links).
    public static func prepare(_ input: Data, quarterTurns: Int = 0, maxBytes: Int) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw Failure.unreadable }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let isPNG = CGImageSourceGetType(source) as String? == UTType.png.identifier
        let turns = normalized(quarterTurns)

        // Nur ein ungedrehtes PNG darf unverändert hochgehen (klein genug in Pixeln und Bytes).
        if isPNG, turns == 0, orientation == 1, max(width, height) <= maxPixelSize, input.count <= maxBytes {
            return Prepared(data: input, mimeType: "image/png", fileExtension: "png", width: width, height: height)
        }

        // EXIF-Ausrichtung anwenden und skalieren, dann die Nutzerdrehung in die Pixel schreiben.
        guard let oriented = orientedImage(source, maxPixelSize: maxPixelSize),
              let image = rotated(oriented, quarterTurns: turns)
        else { throw Failure.unreadable }

        if isPNG, let data = encode(image, type: .png, quality: nil), data.count <= maxBytes {
            return Prepared(data: data, mimeType: "image/png", fileExtension: "png", width: image.width, height: image.height)
        }
        for quality in [0.85, 0.7, 0.55, 0.4] {
            guard let data = encode(image, type: .jpeg, quality: quality) else { throw Failure.unreadable }
            if data.count <= maxBytes {
                return Prepared(data: data, mimeType: "image/jpeg", fileExtension: "jpg",
                                width: image.width, height: image.height)
            }
        }
        throw Failure.tooLarge(maxBytes: maxBytes)
    }

    /// Vorschau für den Schritt „Bild drehen“: EXIF-Ausrichtung angewendet (wie in Fotos), auf `maxPixelSize` verkleinert.
    public static func previewImage(_ input: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return orientedImage(source, maxPixelSize: maxPixelSize)
    }

    /// Dreht ein Bild in 90°-Schritten im Uhrzeigersinn (negativ = gegen den Uhrzeigersinn).
    public static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = normalized(quarterTurns)
        guard turns != 0 else { return image }
        let swap = turns % 2 == 1
        let width = swap ? image.height : image.width
        let height = swap ? image.width : image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // CoreGraphics: y nach oben, positive Winkel gegen den Uhrzeigersinn → im Uhrzeigersinn = negativer Winkel.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    static func normalized(_ quarterTurns: Int) -> Int { ((quarterTurns % 4) + 4) % 4 }

    /// Dekodiert mit angewendeter EXIF-Ausrichtung (`kCGImageSourceCreateThumbnailWithTransform`), höchstens `maxPixelSize`.
    static func orientedImage(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Kodiert ohne Metadaten – das Ergebnis trägt also kein Orientation-Tag.
    static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
