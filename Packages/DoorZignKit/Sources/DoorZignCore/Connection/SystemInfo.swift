import DoorZignAPI
import Foundation

/// Bekannte Feature-Kennungen aus `System.features` (v1). Unbekannte Werte werden ignoriert.
public enum Feature: String, Sendable, CaseIterable {
    case authPassword = "auth.password"
    case authSSO = "auth.sso"
    case calendarICal = "calendar.ical"
    case calendarZeitwart = "calendar.zeitwart"
    case adhoc
    case schedules
    case identify
    case mediaUpload = "media.upload"
    case mediaLibrary = "media.library"
}

/// Aufbereitete Systeminformationen inkl. Kompatibilitätsprüfung.
public struct SystemInfo: Equatable, Sendable {
    public let raw: Components.Schemas.System

    public init(_ raw: Components.Schemas.System) {
        self.raw = raw
    }

    public var name: String { raw.name }
    public var instanceId: String { raw.instanceId }
    public var timezone: TimeZone? { TimeZone(identifier: raw.timezone) }
    public var systemType: SystemType { raw.systemType == .edge ? .edge : .cloud }

    public func has(_ feature: Feature) -> Bool {
        raw.features.contains(feature.rawValue)
    }

    public enum Compatibility: Equatable, Sendable {
        case compatible
        /// Die App ist zu alt („Bitte App aktualisieren“).
        case appUpdateRequired
        /// Das System spricht eine andere Major-Version („System nicht kompatibel“).
        case incompatibleSystem
    }

    public func compatibility(appVersion: String) -> Compatibility {
        let major = raw.apiVersion.split(separator: ".").first.flatMap { Int($0) }
        guard major == 1 else { return .incompatibleSystem }
        return Self.compare(appVersion, raw.minAppVersion) == .orderedAscending ? .appUpdateRequired : .compatible
    }

    /// Vergleicht Versionsnummern komponentenweise numerisch (`1.10.0` > `1.9.3`).
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(lhs), b = parts(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
