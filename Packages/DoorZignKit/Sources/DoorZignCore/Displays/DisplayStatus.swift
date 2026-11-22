import DoorZignAPI
import Foundation

public typealias Display = Components.Schemas.Display

/// Akkustand nach ui-spec: < 15 % kritisch, < 30 % schwach.
public enum BatteryLevel: Equatable, Sendable {
    case critical, low, normal, unknown

    public init(percent: Int?) {
        switch percent {
        case nil: self = .unknown
        case let p? where p < 15: self = .critical
        case let p? where p < 30: self = .low
        default: self = .normal
        }
    }

    public var label: String {
        switch self {
        case .critical: L("Kritisch")
        case .low: L(key: "battery.low", "Schwach")
        case .normal: L("Normal")
        case .unknown: L("Unbekannt")
        }
    }
}

/// Signalstärke nach ui-spec: ≥ −65 dBm gut, ≥ −80 dBm mittel, sonst schwach.
public enum SignalQuality: Equatable, Sendable {
    case good, medium, weak, unknown

    public init(rssi: Int?) {
        switch rssi {
        case nil: self = .unknown
        case let r? where r >= -65: self = .good
        case let r? where r >= -80: self = .medium
        default: self = .weak
        }
    }

    public var label: String {
        switch self {
        case .good: L("Gut")
        case .medium: L("Mittel")
        case .weak: L(key: "signal.weak", "Schwach")
        case .unknown: L("Unbekannt")
        }
    }

    /// Anzahl gefüllter Balken (von 3).
    public var bars: Int {
        switch self {
        case .good: 3
        case .medium: 2
        case .weak: 1
        case .unknown: 0
        }
    }
}

/// Filter der Displayliste.
public enum DisplayFilter: String, CaseIterable, Identifiable, Sendable {
    case all, offline, lowBattery, error, transferring

    public var id: Self { self }

    public var label: String {
        switch self {
        case .all: L("Alle")
        case .offline: L("Offline")
        case .lowBattery: L("Akku schwach")
        case .error: L("Fehler")
        case .transferring: L("Übertragung offen")
        }
    }

    public func matches(_ display: Display) -> Bool {
        switch self {
        case .all: true
        case .offline: !display.online
        case .lowBattery: [.critical, .low].contains(BatteryLevel(percent: display.battery))
        case .error: !(display.lastError ?? "").isEmpty
        case .transferring: display.openJobs > 0
        }
    }
}

extension Display {
    public var batteryLevel: BatteryLevel { BatteryLevel(percent: battery) }
    public var signalQuality: SignalQuality { SignalQuality(rssi: signal) }

    /// ETag der Vorschau der aktiven Ansicht (aus `slots`).
    public var activePreviewEtag: String? {
        slots.first { $0.slot == activeSlot }?.previewEtag
    }

    /// Mindestens Stufe `level`? (`view ⊂ switch ⊂ edit`)
    public func allows(_ required: Components.Schemas.AccessLevel) -> Bool {
        func rank(_ l: Components.Schemas.AccessLevel) -> Int {
            switch l {
            case .view: 0
            case ._switch: 1
            case .edit: 2
            }
        }
        return rank(level) >= rank(required)
    }
}

public enum DisplayListLogic {
    /// Filtert, durchsucht (angezeigter Name, Ort, MAC) und sortiert nach dem angezeigten Namen.
    public static func apply(_ displays: [Display], filter: DisplayFilter, search: String) -> [Display] {
        displays
            .filter(filter.matches)
            .filter { DisplayNaming.matches($0, query: search) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
