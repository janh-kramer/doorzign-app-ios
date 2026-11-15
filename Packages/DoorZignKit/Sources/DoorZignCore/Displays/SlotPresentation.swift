import DoorZignAPI
import Foundation

public typealias Slot = Components.Schemas.Slot
public typealias SlotContent = Components.Schemas.SlotContent

extension SlotContent {
    public var typeLabel: String {
        switch self {
        case .text: "Text"
        case .image: "Bild"
        case .calendar(let calendar): calendar.source == .zeitwart ? "Raumanzeige" : "Kalender"
        case .deactivated: "Deaktiviert"
        }
    }

    public var isDeactivated: Bool {
        if case .deactivated = self { return true }
        return false
    }

    public var isCalendar: Bool {
        if case .calendar = self { return true }
        return false
    }
}

extension Slot {
    /// Ob „nicht übertragen“ als Warnung gelten soll.
    public enum TransferTone: Sendable { case neutral, busy, warning, failure }

    /// Kurzstatus der Übertragung dieser Ansicht.
    ///
    /// `transferred = false` ist nur bei der aktiven Ansicht ein Warnhinweis: Manche Backends (Zeitwart)
    /// übertragen inaktive Ansichten erst beim Umschalten – dort ist das der Normalfall, kein Fehler.
    public func transferStatus(isActive: Bool) -> (label: String, tone: TransferTone) {
        if let transfer, transfer.status.isOpen { return (transfer.status.label, .busy) }
        if let transfer, transfer.status.isFailure { return (transfer.status.label, .failure) }
        if transferred { return ("Auf dem Display", .neutral) }
        return isActive ? ("Nicht übertragen", .warning) : ("Wird beim Anzeigen übertragen", .neutral)
    }
}
