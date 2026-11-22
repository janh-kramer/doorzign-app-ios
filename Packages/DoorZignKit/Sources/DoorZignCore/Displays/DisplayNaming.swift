import DoorZignAPI
import Foundation

/// Anzeigename eines Displays (decisions 48, ui-spec §2): Ist `name` leer oder besteht nur aus
/// Leerzeichen, steht überall dort, wo sonst der Name steht, die MAC so, wie das Backend sie liefert.
public enum DisplayNaming {
    public static func displayName(name: String?, mac: String) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return mac }
        return name
    }

    /// Suchtreffer: angezeigter Name, Ort oder – immer – die MAC.
    public static func matches(_ display: Display, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty
            || display.displayName.localizedCaseInsensitiveContains(query)
            || (display.location ?? "").localizedCaseInsensitiveContains(query)
            || display.mac.localizedCaseInsensitiveContains(query)
    }
}

extension Display {
    /// Name, bei leerem Namen die MAC (decisions 48).
    public var displayName: String { DisplayNaming.displayName(name: name, mac: mac) }
}

extension Job {
    /// Anzeigename des Displays eines Auftrags. Aufträge tragen keine MAC; ist der Name leer,
    /// wird die MAC aus der bekannten Displayliste verwendet (`mac`), sonst `nil`.
    public func displayLabel(mac: String?) -> String? {
        guard let name = displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return mac.flatMap { $0.isEmpty ? nil : $0 }
        }
        return name
    }
}
