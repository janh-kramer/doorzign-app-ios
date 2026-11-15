import DoorZignAPI
import Foundation

public typealias Job = Components.Schemas.Job
public typealias JobStatus = Components.Schemas.JobStatus

extension JobStatus {
    /// Bezeichnungen nach ui-spec §7.
    public var label: String {
        switch self {
        case .pending: L("Wartet")
        case .progress: L("Wird übertragen")
        case .retry: L("Neuer Versuch geplant")
        case .done: L("Erledigt")
        case .failed: L("Fehlgeschlagen")
        case .skipped: L("Übersprungen")
        case .abandoned: L("Abgebrochen")
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
        case "upload_image": slot.map { L("Ansicht \($0) übertragen") } ?? L("Inhalt übertragen")
        case "press_button": slot.map { L("Auf Ansicht \($0) umschalten") } ?? L("Ansicht umschalten")
        case "unbind_button": L("Ansicht deaktivieren")
        case "identify": L("Display finden")
        default: L("Auftrag")
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
