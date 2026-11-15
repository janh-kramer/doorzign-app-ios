import Foundation

/// Datei-Cache (Vorschaubilder, Antworten), streng getrennt pro `instanceId`.
/// Beim Systemwechsel wird das gesamte Wurzelverzeichnis gelöscht.
public struct InstanceCache: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.root = caches.appendingPathComponent("instances", isDirectory: true)
        }
    }

    /// Verzeichnis einer Installation. Die `instanceId` wird für das Dateisystem entschärft.
    public func directory(for instanceId: String) -> URL {
        root.appendingPathComponent(Self.sanitize(instanceId), isDirectory: true)
    }

    /// Löscht den Cache aller Installationen.
    public func wipeAll() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// Löscht alle Installationen außer der angegebenen (Aufräumen nach Absturz während eines Wechsels).
    public func wipeAll(except instanceId: String) throws {
        let keep = Self.sanitize(instanceId)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent != keep {
            try FileManager.default.removeItem(at: entry)
        }
    }

    static func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "_" : cleaned
    }
}

/// Cache für Vorschau-PNGs mit ETag (`If-None-Match` → 304).
public actor PreviewCache {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory.appendingPathComponent("previews", isDirectory: true)
    }

    public struct Entry: Sendable {
        public let data: Data
        public let etag: String?
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(InstanceCache.sanitize(key) + ".png")
    }

    private func etagURL(_ key: String) -> URL {
        directory.appendingPathComponent(InstanceCache.sanitize(key) + ".etag")
    }

    public func entry(for key: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
        let etag = (try? String(contentsOf: etagURL(key), encoding: .utf8))
        return Entry(data: data, etag: etag)
    }

    public func store(_ data: Data, etag: String?, for key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let etag {
            try? etag.write(to: etagURL(key), atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: etagURL(key))
        }
    }

    public func remove(for key: String) {
        try? FileManager.default.removeItem(at: fileURL(key))
        try? FileManager.default.removeItem(at: etagURL(key))
    }
}
