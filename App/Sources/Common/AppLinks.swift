import Foundation

/// Rechtliche Links des App-Herausgebers (nicht instanzabhängig, daher nicht im Vertrag).
/// Einzige Stelle für diese URLs – Android verwendet dieselben Werte.
enum AppLinks {
    // TODO: von Jan bestätigen
    static let imprint = URL(string: "https://doorzign.de/impressum")!
    // TODO: von Jan bestätigen
    static let privacy = URL(string: "https://doorzign.de/datenschutz")!
}
