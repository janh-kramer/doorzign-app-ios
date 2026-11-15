import Foundation
import Security

/// Wie das Serverzertifikat geprüft wird.
public enum TrustPolicy: Sendable, Equatable {
    /// Normale Prüfung durch das System (Cloud).
    case system
    /// Edge: Die Serverkette muss zu der CA mit genau diesem Fingerprint führen (siehe docs/edge-connection.md).
    case pinned(fingerprint: String)
    /// Trust on first use: jedes Zertifikat wird für die Abfrage von `GET /system` akzeptiert,
    /// der CA-Fingerprint wird festgehalten und muss vom Benutzer bestätigt werden.
    /// Darf NIE für Anfragen mit Zugangsdaten verwendet werden.
    case captureForConfirmation
}

/// URLSession-Delegate für Zertifikats-Pinning. Ein eigenes Exemplar pro URLSession.
///
/// Edge-Gateways eines Verbunds teilen eine CA; gepinnt wird der SHA-256 über die DER-Kodierung des
/// CA-Zertifikats. Die Serverkette wird gegen genau diese CA als einzigen Vertrauensanker geprüft
/// (Signaturen und Gültigkeitszeitraum), der Hostname wird ignoriert, da Gateways oft per IP erreichbar sind.
/// Voraussetzung: Der Server liefert das CA-Zertifikat in der TLS-Kette mit.
public final class PinningSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let policy: TrustPolicy
    private let lock = NSLock()
    private var _observedFingerprint: String?

    /// CA-Fingerprint der zuletzt gesehenen Kette (für TOFU und Fehlermeldungen bei Abweichung).
    public var observedFingerprint: String? { lock.withLock { _observedFingerprint } }

    public init(policy: TrustPolicy) {
        self.policy = policy
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }

        switch policy {
        case .system:
            return (.performDefaultHandling, nil)

        case .pinned(let expected):
            let chain = Self.chain(trust)
            lock.withLock { _observedFingerprint = chain.last.map(Fingerprint.sha256(of:)) }
            return Self.evaluate(trust, chain: chain, pinnedCA: expected)
                ? (.useCredential, URLCredential(trust: trust))
                : (.cancelAuthenticationChallenge, nil)

        case .captureForConfirmation:
            let chain = Self.chain(trust)
            guard let root = chain.last else { return (.cancelAuthenticationChallenge, nil) }
            let fingerprint = Fingerprint.sha256(of: root)
            lock.withLock { _observedFingerprint = fingerprint }
            // Auch beim ersten Kontakt muss die Kette in sich stimmig sein (Leaf von dieser CA signiert).
            return Self.evaluate(trust, chain: chain, pinnedCA: fingerprint)
                ? (.useCredential, URLCredential(trust: trust))
                : (.cancelAuthenticationChallenge, nil)
        }
    }

    static func chain(_ trust: SecTrust) -> [SecCertificate] {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    }

    /// Prüft die Kette mit der gepinnten CA als einzigem Anker, ohne Hostnamenprüfung.
    static func evaluate(_ trust: SecTrust, chain: [SecCertificate], pinnedCA: String) -> Bool {
        guard let anchor = chain.first(where: { Fingerprint.sha256(of: $0) == pinnedCA }) else { return false }
        guard SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
