import Foundation

/// Art des verbundenen Backends. Dient nur der Anzeige – die App-Logik verzweigt nie danach,
/// sondern ausschließlich nach `System.features`.
public enum SystemType: String, Codable, Sendable {
    case edge
    case cloud
}

/// Das eine aktive Verbindungsprofil `{systemType, instanceId, baseUrl, name, tlsFingerprint?}`.
public struct ConnectionProfile: Codable, Equatable, Sendable {
    public var systemType: SystemType
    /// Stabile ID der Installation; trennt Zugangsdaten und Cache.
    public var instanceId: String
    /// Basis-URL inklusive `/mobile/v1`, z. B. `https://firma.zeitwart.de/mobile/v1`.
    public var baseURL: URL
    /// Weitere erreichbare Adressen (Edge-Cluster aus dem QR-Code), in Reihenfolge der Bevorzugung.
    public var alternativeURLs: [URL]
    public var name: String
    /// Gepinnter Zertifikats-Fingerprint (SHA-256, normalisiert: 64 Hex-Zeichen klein, ohne Trenner).
    /// `nil` = normale Systemprüfung des Zertifikats (Cloud).
    public var tlsFingerprint: String?

    public init(
        systemType: SystemType,
        instanceId: String,
        baseURL: URL,
        alternativeURLs: [URL] = [],
        name: String,
        tlsFingerprint: String?
    ) {
        self.systemType = systemType
        self.instanceId = instanceId
        self.baseURL = baseURL
        self.alternativeURLs = alternativeURLs
        self.name = name
        self.tlsFingerprint = tlsFingerprint
    }
}
