import CryptoKit
import Foundation

/// PKCE-Parameter (RFC 7636, Methode S256) und `state` für den SSO-Ablauf.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init() {
        self.init(verifier: Self.randomURLSafe(byteCount: 48), state: Self.randomURLSafe(byteCount: 16))
    }

    init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        self.state = state
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Aufbau der SSO-Start-URL und Auswertung des Rückrufs `doorzign://auth/callback`.
public enum SSOFlow {
    public static let callbackScheme = "doorzign"
    public static let redirectURI = "doorzign://auth/callback"

    public static func startURL(
        baseURL: URL, provider: String, pkce: PKCE, deviceName: String,
        platform: String = "ios", appVersion: String? = nil
    ) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/sso/start"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "device_name", value: deviceName),
            URLQueryItem(name: "platform", value: platform),
        ] + (appVersion.map { [URLQueryItem(name: "app_version", value: $0)] } ?? [])
        return components.url
    }

    public enum CallbackError: Error, Equatable {
        case invalidCallback
        case stateMismatch
        case provider(code: String)
    }

    /// Liefert den Einmalcode aus dem Rückruf oder einen Fehler.
    public static func code(from callback: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == callbackScheme, components.host == "auth", components.path == "/callback"
        else { throw CallbackError.invalidCallback }
        let items = components.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw CallbackError.stateMismatch }
        if let error = value("error") { throw CallbackError.provider(code: error) }
        guard let code = value("code"), !code.isEmpty else { throw CallbackError.invalidCallback }
        return code
    }
}
