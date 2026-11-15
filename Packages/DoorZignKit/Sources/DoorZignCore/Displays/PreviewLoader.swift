import DoorZignAPI
import Foundation
import OpenAPIRuntime

/// Lädt Vorschau-PNGs (mit Bearer-Token über den Client) und cacht sie pro Installation mit ETag.
/// Ist der `previewEtag` aus `Display.slots` bereits im Cache, entfällt die Anfrage ganz.
public actor PreviewLoader {
    private let client: Client
    private let cache: PreviewCache
    /// Laufende Ladevorgänge, damit dieselbe Vorschau nicht mehrfach parallel geladen wird.
    private var inFlight: [String: Task<Data?, Never>] = [:]

    /// Obergrenze für ein Vorschaubild (Panelauflösung, PNG).
    static let maxBytes = 4 * 1024 * 1024

    public init(client: Client, cache: PreviewCache) {
        self.client = client
        self.cache = cache
    }

    public static func key(displayId: String, slot: Int) -> String { "\(displayId)-\(slot)" }

    /// Liefert die PNG-Daten oder `nil`, wenn keine Vorschau verfügbar ist.
    /// Vertrag 1.2.3: `previewEtag == nil` heißt genau „preview.png liefert 404“ (deaktivierte Ansicht
    /// oder Bildansicht ohne Bild) – dann keine Anfrage, veraltete Cache-Einträge verwerfen.
    public func preview(displayId: String, slot: Int, expectedEtag: String?) async -> Data? {
        let key = Self.key(displayId: displayId, slot: slot)
        guard let expectedEtag else {
            await cache.remove(for: key)
            return nil
        }
        if let task = inFlight[key] { return await task.value }

        let cached = await cache.entry(for: key)
        if let cached, ETag.matches(cached.etag, expectedEtag) {
            return cached.data
        }
        let task = Task { await self.fetch(displayId: displayId, slot: slot, key: key, cached: cached) }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        return data
    }

    private func fetch(displayId: String, slot: Int, key: String, cached: PreviewCache.Entry?) async -> Data? {
        do {
            let output = try await client.getSlotPreview(
                path: .init(displayId: displayId, slot: slot),
                headers: .init(ifNoneMatch: cached?.etag)
            )
            switch output {
            case .ok(let ok):
                let data = try await Data(collecting: ok.body.png, upTo: Self.maxBytes)
                await cache.store(data, etag: ok.headers.eTag, for: key)
                return data
            case .notModified:
                return cached?.data
            case .notFound:
                // Inzwischen keine Vorschau mehr (z. B. Ansicht gerade deaktiviert).
                await cache.remove(for: key)
                return nil
            default:
                return cached?.data
            }
        } catch {
            // Offline: zuletzt bekannte Vorschau anzeigen.
            return cached?.data
        }
    }
}

/// ETag-Vergleich tolerant gegenüber `W/` und fehlenden Anführungszeichen
/// (Vertrag 1.2.2: `previewEtag` = ETag-Header inkl. Anführungszeichen; ältere Edge-Versionen ohne).
public enum ETag {
    public static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return value
    }

    public static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return normalized(a) == normalized(b)
    }
}
