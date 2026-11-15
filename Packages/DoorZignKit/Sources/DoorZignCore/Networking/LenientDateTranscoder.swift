import Foundation
import OpenAPIRuntime

/// ISO-8601-Zeitstempel mit und ohne Sekundenbruchteile (Laravel liefert standardmäßig `…00.000000Z`).
/// Ausgegeben wird immer `YYYY-MM-DDTHH:MM:SSZ`.
public struct LenientDateTranscoder: DateTranscoder {
    public init() {}

    public func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601)
    }

    public func decode(_ string: String) throws -> Date {
        if let date = try? Date(string, strategy: .iso8601) {
            return date
        }
        if let date = Self.parseFractional(string) {
            return date
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Ungültiger ISO-8601-Zeitstempel: \(string)")
        )
    }

    /// Schneidet Sekundenbruchteile beliebiger Länge ab und rechnet sie wieder hinzu.
    static func parseFractional(_ string: String) -> Date? {
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let afterDot = string[string.index(after: dot)...]
        let digits = afterDot.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = afterDot.dropFirst(digits.count)
        guard let base = try? Date(String(string[..<dot]) + rest, strategy: .iso8601),
              let fraction = Double("0." + digits)
        else { return nil }
        return base.addingTimeInterval(fraction)
    }
}
