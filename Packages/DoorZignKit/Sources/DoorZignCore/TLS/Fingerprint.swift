import CryptoKit
import Foundation
import Security

/// SHA-256-Fingerprint eines Serverzertifikats (über die DER-Daten des Leaf-Zertifikats).
public enum Fingerprint {
    /// Normalisiert beliebige Schreibweisen (`AB:CD…`, `ab cd…`, `abcd…`) auf 64 Hex-Zeichen klein.
    /// Gibt `nil` zurück, wenn es kein gültiger SHA-256-Wert ist.
    public static func normalize(_ raw: String) -> String? {
        let hex = raw.lowercased().filter { !":- ".contains($0) }
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    public static func sha256(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Lesbare Darstellung in Blöcken: `AB:CD:EF:…`.
    public static func formatted(_ normalized: String) -> String {
        stride(from: 0, to: normalized.count, by: 2).map { offset -> String in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            return normalized[start..<normalized.index(start, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
    }

    /// Kurzform für die TOFU-Bestätigung: erste und letzte vier Blöcke, z. B. `AB:CD:EF:01 … 9A:BC:DE:F0`.
    public static func short(_ normalized: String) -> String {
        let blocks = formatted(normalized).split(separator: ":")
        guard blocks.count > 8 else { return formatted(normalized) }
        return blocks.prefix(4).joined(separator: ":") + " … " + blocks.suffix(4).joined(separator: ":")
    }
}
