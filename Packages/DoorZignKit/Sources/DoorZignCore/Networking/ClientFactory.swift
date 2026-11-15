import DoorZignAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Ein Client samt eigener URLSession. `invalidate()` bricht alle laufenden Anfragen ab (Systemwechsel).
public final class APIConnection: Sendable {
    public let client: Client
    public let session: URLSession
    public let delegate: PinningSessionDelegate
    public let baseURL: URL

    init(client: Client, session: URLSession, delegate: PinningSessionDelegate, baseURL: URL) {
        self.client = client
        self.session = session
        self.delegate = delegate
        self.baseURL = baseURL
    }

    public func invalidate() {
        session.invalidateAndCancel()
    }
}

public enum ClientFactory {
    static let configuration = Configuration(dateTranscoder: LenientDateTranscoder())

    public static func makeConnection(
        baseURL: URL,
        trust: TrustPolicy,
        middlewares: [any ClientMiddleware] = []
    ) -> APIConnection {
        let delegate = PinningSessionDelegate(policy: trust)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        // Kein gemeinsamer Cookie- oder URL-Cache: Daten verschiedener Systeme dürfen sich nie mischen.
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let transport = URLSessionTransport(configuration: .init(session: session))
        let client = Client(
            serverURL: baseURL,
            configuration: configuration,
            transport: transport,
            middlewares: [AcceptLanguageMiddleware()] + middlewares + [HeaderDecodingMiddleware()]
        )
        return APIConnection(client: client, session: session, delegate: delegate, baseURL: baseURL)
    }

    public static func trustPolicy(for profile: ConnectionProfile) -> TrustPolicy {
        if let fingerprint = profile.tlsFingerprint { .pinned(fingerprint: fingerprint) } else { .system }
    }
}
