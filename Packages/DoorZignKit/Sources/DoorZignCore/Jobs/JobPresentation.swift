import DoorZignAPI
import Foundation

public typealias Job = Components.Schemas.Job
public typealias JobStatus = Components.Schemas.JobStatus

extension JobStatus {
    /// Bezeichnungen nach ui-spec §7.
    public var label: String {
        switch self {
        case .pending: "Wartet"
        case .progress: "Wird übertragen"
        case .retry: "Neuer Versuch geplant"
        case .done: "Übertragen"
        case .failed: "Fehlgeschlagen"
        case .skipped: "Übersprungen"
        case .abandoned: "Abgebrochen"
        }
    }

    /// Offen = pending, progress, retry.
    public var isOpen: Bool {
        switch self {
        case .pending, .progress, .retry: true
        case .done, .failed, .skipped, .abandoned: false
        }
    }

    public var isFailure: Bool { self == .failed || self == .abandoned }
}

extension Job {
    /// Auftragsart; offene Werteliste, Unbekanntes neutral anzeigen.
    public var typeLabel: String {
        switch _type {
        case "upload_image": slot.map { "Ansicht \($0) übertragen" } ?? "Inhalt übertragen"
        case "press_button": slot.map { "Auf Ansicht \($0) umschalten" } ?? "Ansicht umschalten"
        case "unbind_button": "Ansicht deaktivieren"
        case "identify": "Display finden"
        default: "Auftrag"
        }
    }

    /// Offen und nicht erst in der Zukunft geplant.
    public func isActive(now: Date = Date()) -> Bool {
        status.isOpen && (scheduledAt.map { $0 <= now } ?? true)
    }
}

/// Polling-Regel nach ui-spec §7: Solange offene Aufträge existieren alle 5 s, höchstens 5 min lang,
/// danach (und ohne offene Aufträge) alle 30 s.
public enum JobPolling {
    public static let fast: Duration = .seconds(5)
    public static let slow: Duration = .seconds(30)
    public static let fastWindow: TimeInterval = 5 * 60

    /// `fastSince`: Zeitpunkt, seit dem ununterbrochen offene Aufträge bestehen.
    public static func interval(hasOpenJobs: Bool, fastSince: Date?, now: Date = Date()) -> Duration {
        guard hasOpenJobs, let fastSince, now.timeIntervalSince(fastSince) < fastWindow else { return slow }
        return fast
    }
}
