import Foundation

/// Texte aus DoorZignCore. Quellsprache Deutsch: Der deutsche Text ist der Schlüssel,
/// Übersetzungen liegen in `Resources/<sprache>.lproj/Localizable.strings`.
/// Platzhalter im Schlüssel: `%@` für Strings, `%lld` für Ganzzahlen.
public enum CoreL10n {
    /// Nur für Tests: Sprache gezielt erzwingen, z. B. `CoreL10n.$bundleOverride.withValue(CoreL10n.bundle(language: "en"))`.
    @TaskLocal public static var bundleOverride: Bundle?

    static var bundle: Bundle { bundleOverride ?? preferred }

    /// Sprache nach den bevorzugten Sprachen des Benutzers (inkl. App-Sprache aus den iOS-Einstellungen),
    /// unabhängig von der Sprache des Host-Prozesses (Tests).
    static let preferred: Bundle = {
        bundle(language: language) ?? .module
    }()

    /// Sprache der Oberfläche als Code (`de` oder `en`), z. B. für `Accept-Language`.
    public static let language: String = Bundle.preferredLocalizations(
        from: Bundle.module.localizations, forPreferences: Locale.preferredLanguages
    ).first ?? "de"

    /// Bundle einer einzelnen Sprache (für Tests).
    public static func bundle(language: String) -> Bundle? {
        Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

/// Lokalisierter Text; der deutsche Text ist zugleich Schlüssel.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: CoreL10n.bundle)
}

/// Lokalisierter Text mit eigenem Schlüssel (wenn derselbe deutsche Text je nach Kontext anders übersetzt wird).
func L(key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: defaultValue, bundle: CoreL10n.bundle)
}
