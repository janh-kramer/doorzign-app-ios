import UIKit

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Vorschlag für den Gerätenamen („Verbundene Geräte“): Gerätetyp und Modellkennung,
    /// z. B. „iPhone (iPhone16,1)“. Der Benutzer kann ihn auf der Anmeldeseite ändern.
    /// `UIDevice.name` liefert seit iOS 16 ohne Sonder-Entitlement ohnehin nur „iPhone“.
    @MainActor static var deviceName: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let model = UIDevice.current.model
        // Simulator meldet x86_64/arm64; dann nur das Modell.
        return identifier.contains(",") ? "\(model) (\(identifier))" : model
    }
}
