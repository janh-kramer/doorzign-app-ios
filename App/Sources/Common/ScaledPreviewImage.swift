import DoorZignCore
import SwiftUI
import UIKit

/// Vorschau-PNG „scaledToFit“ (decisions 47): Wird verkleinert, rechnet die View das Bild vorab flächenmittelnd
/// auf Zielgröße × displayScale herunter (sonst wird das Dithering zu Rauschen). Wird vergrößert oder 1:1
/// dargestellt, bleibt es pixelgenau (Nearest-Neighbor).
struct ScaledPreviewImage: View {
    let data: Data
    /// Stabiler Schlüssel für den Speicher-Cache (z. B. Display, Ansicht und ETag). Ohne: Inhalt der Daten.
    var cacheKey: String?

    @Environment(\.displayScale) private var displayScale
    @State private var scaled: (id: String, image: CGImage)?

    var body: some View {
        GeometryReader { geometry in
            let pixelSize = PreviewScaling.pixelSize(of: data)
            let target = pixelSize.flatMap {
                PreviewScaling.targetPixelSize(image: $0, frame: geometry.size, displayScale: displayScale)
            }
            Group {
                if let target {
                    let id = Self.cacheID(key: cacheKey, data: data, target: target)
                    if let image = (scaled?.id == id ? scaled?.image : nil) ?? PreviewImageCache.shared.image(for: id) {
                        Image(decorative: image, scale: displayScale)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Color.clear.task(id: id) {
                            let data = data
                            let image = await Task.detached(priority: .userInitiated) {
                                PreviewScaling.downscaled(data, to: target)
                            }.value
                            guard let image else { return }
                            PreviewImageCache.shared.store(image, for: id)
                            scaled = (id, image)
                        }
                    }
                } else if let image = UIImage(data: data) {
                    // Vergrößern oder 1:1: pixelgenau.
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    static func cacheID(key: String?, data: Data, target: CGSize) -> String {
        let content = key ?? "data-" + String(data.count) + "-" + String(data.hashValue)
        return content + "@" + String(Int(target.width)) + "x" + String(Int(target.height))
    }
}

/// Speicher-Cache der verkleinerten Vorschauen; Schlüssel enthält den ETag bzw. Inhalt und die Zielgröße.
@MainActor
final class PreviewImageCache {
    static let shared = PreviewImageCache()
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 300
        return cache
    }()

    func image(for id: String) -> CGImage? { cache.object(forKey: id as NSString) }
    func store(_ image: CGImage, for id: String) { cache.setObject(image, forKey: id as NSString) }
}
