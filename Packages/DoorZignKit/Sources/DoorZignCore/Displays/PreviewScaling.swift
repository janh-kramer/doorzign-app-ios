import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Skalierung der Vorschau-PNGs (ui-spec §3, decisions 47): Verkleinern immer flächenmittelnd, sonst wird das
/// Dithering der E-Paper-Vorschau zu Rauschen. Nearest-Neighbor nur beim Vergrößern (pixelgenaue Ansicht).
public enum PreviewScaling {
    /// Pixelmaße des Bildes, ohne es zu dekodieren.
    public static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Zielgröße in Pixeln für „scaledToFit“ in `frame` (Punkte) bei `displayScale`.
    /// `nil`, wenn nicht verkleinert werden muss (Bild passt in Originalgröße oder wird vergrößert).
    public static func targetPixelSize(image: CGSize, frame: CGSize, displayScale: CGFloat) -> CGSize? {
        guard image.width > 0, image.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let fit = min(frame.width / image.width, frame.height / image.height) * displayScale
        guard fit < 1 else { return nil }
        return CGSize(width: max(1, (image.width * fit).rounded()), height: max(1, (image.height * fit).rounded()))
    }

    /// Dekodiert und verkleinert flächenmittelnd (vImage, Antialiasing) auf genau `size` Pixel.
    public static func downscaled(_ data: Data, to size: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return downscaled(image, to: size)
    }

    public static func downscaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(CGColorSpace(name: CGColorSpace.sRGB)!),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent
        )
        var input = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&input, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        defer { free(input.data) }
        var output = vImage_Buffer()
        guard vImageBuffer_Init(&output, vImagePixelCount(height), vImagePixelCount(width), 32,
                                vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        defer { free(output.data) }
        guard vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
        else { return nil }
        return vImageCreateCGImageFromBuffer(&output, &format, nil, nil, vImage_Flags(kvImageNoFlags), nil)?
            .takeRetainedValue()
    }
}
