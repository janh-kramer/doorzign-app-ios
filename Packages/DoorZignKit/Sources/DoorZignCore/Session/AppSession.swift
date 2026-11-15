import DoorZignAPI
import Foundation
import Observation
import OpenAPIRuntime

/// Kontext der Anmeldeseite: geprüftes System, noch ohne Zugangsdaten.
public struct LoginContext: Sendable {
    public let profile: ConnectionProfile
    public let system: SystemInfo
    /// Lokales Konto mit Benutzername/Passwort.
    public let passwordEnabled: Bool
    /// Provider mit `flow = browser` (Systembrowser, PKCE).
    public let browserProviders: [Components.Schemas.SsoProvider]
    /// Provider mit `flow = password` (z. B. Winbiap): Formular in der App, `POST /auth/login` mit `provider`.
    public let passwordProviders: [Components.Schemas.SsoProvider]
}

/// Angemeldeter Zustand mit einsatzbereitem API-Client.
public struct SignedInContext: Sendable {
    public let profile: ConnectionProfile
    public let client: Client
    public let previews: PreviewLoader
    public var system: SystemInfo?
    public var me: Components.Schemas.Me?
}

/// Zentrale Sitzung: genau ein aktives Verbindungsprofil.
@MainActor
@Observable
public final class AppSession {
    public enum Phase {
        case starting
        case onboarding
        case login(LoginContext)
        case signedIn(SignedInContext)
    }

    public private(set) var phase: Phase = .starting
    /// Hinweis nach automatischer Abmeldung (z. B. Token widerrufen).
    public var notice: String?

    public let appVersion: String
    /// Name für „Verbundene Geräte“; vom Benutzer auf der Anmeldeseite änderbar.
    public var deviceName: String
    private let store: CredentialStoring
    private let instanceCache: InstanceCache

    @ObservationIgnored private var connection: APIConnection?
    @ObservationIgnored private var tokenManager: TokenManager?

    public init(
        appVersion: String,
        deviceName: String,
        store: CredentialStoring = KeychainCredentialStore(),
        instanceCache: InstanceCache = InstanceCache()
    ) {
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.store = store
        self.instanceCache = instanceCache
    }

    // MARK: Start

    /// Lädt das gespeicherte Profil. Mit Tokens geht es direkt in die App, sonst ins Onboarding.
    public func bootstrap() async {
        guard let profile = try? store.loadProfile() else {
            // Kein Profil: Reste früherer Verbindungen restlos entfernen.
            try? store.wipe()
            try? instanceCache.wipeAll()
            phase = .onboarding
            return
        }
        try? instanceCache.wipeAll(except: profile.instanceId)
        guard let tokens = try? store.loadTokens(instanceId: profile.instanceId) else {
            await prepareLogin(profile: profile)
            return
        }
        activate(profile: profile, tokens: tokens)
        await refreshSignedInInfo()
    }

    // MARK: Onboarding → Anmeldung

    /// Nach erfolgreicher Prüfung (`SystemProbe`) die Anmeldeseite vorbereiten.
    /// Das Profil wird erst nach erfolgreicher Anmeldung gespeichert.
    @discardableResult
    public func prepareLogin(
        probe: ProbeResult,
        pinnedFingerprint: String?,
        alternativeURLs: [URL] = []
    ) async -> APIError? {
        switch probe.system.compatibility(appVersion: appVersion) {
        case .appUpdateRequired:
            return APIError(code: "app_update_required", message: L("Bitte aktualisiere die App, um dich mit diesem System zu verbinden."))
        case .incompatibleSystem:
            return APIError(code: "incompatible", message: L("Dieses System ist nicht mit der App kompatibel."))
        case .compatible:
            break
        }
        let profile = ConnectionProfile(
            systemType: probe.system.systemType,
            instanceId: probe.system.instanceId,
            baseURL: probe.baseURL,
            alternativeURLs: alternativeURLs.filter { $0 != probe.baseURL },
            name: probe.system.name,
            tlsFingerprint: pinnedFingerprint
        )
        return await prepareLogin(profile: profile, system: probe.system)
    }

    @discardableResult
    private func prepareLogin(profile: ConnectionProfile, system knownSystem: SystemInfo? = nil) async -> APIError? {
        let connection = ClientFactory.makeConnection(baseURL: profile.baseURL, trust: ClientFactory.trustPolicy(for: profile))
        defer { connection.session.finishTasksAndInvalidate() }
        do {
            let system: SystemInfo
            if let knownSystem {
                system = knownSystem
            } else {
                system = SystemInfo(try Self.require(try await connection.client.getSystem()) { try $0.ok.body.json })
            }
            let providers = try Self.require(try await connection.client.getAuthProviders()) { try $0.ok.body.json }
            // Maßgeblich ist /auth/providers; SSO-Provider nur mit Feature auth.sso.
            let sso = system.has(.authSSO) ? providers.sso : []
            phase = .login(LoginContext(
                profile: profile,
                system: system,
                passwordEnabled: providers.password,
                browserProviders: sso.filter { $0.flow == .browser },
                passwordProviders: sso.filter { $0.flow == .password }
            ))
            return nil
        } catch {
            let apiError = APIError.from(error)
            if case .starting = phase { phase = .onboarding; notice = apiError.message }
            return apiError
        }
    }

    // MARK: Anmeldung

    /// `provider`: Id eines Providers mit `flow = password`; `nil` = lokales Konto.
    public func login(context: LoginContext, username: String, password: String, provider: String? = nil) async throws {
        let connection = ClientFactory.makeConnection(baseURL: context.profile.baseURL, trust: ClientFactory.trustPolicy(for: context.profile))
        defer { connection.session.finishTasksAndInvalidate() }
        let output: Operations.Login.Output
        do {
            output = try await connection.client.login(body: .json(.init(
                username: username,
                password: password,
                provider: provider,
                deviceName: deviceName,
                platform: Self.platform,
                appVersion: appVersion
            )))
        } catch {
            throw APIError.from(error)
        }
        let pair: Components.Schemas.TokenPair
        switch output {
        case .ok(let ok): pair = try ok.body.json
        case .unauthorized(let r): throw APIError(try r.body.json, statusCode: 401).forLogin
        case .unprocessableContent(let r): throw APIError(try r.body.json, statusCode: 422)
        case .tooManyRequests(let r): throw APIError(try r.body.json, statusCode: 429)
        case .default(let status, let r): throw APIError(try r.body.json, statusCode: status)
        }
        try completeSignIn(context: context, pair: pair)
    }

    /// Tauscht den SSO-Einmalcode (PKCE) gegen Tokens.
    public func completeSSO(context: LoginContext, code: String, verifier: String) async throws {
        let connection = ClientFactory.makeConnection(baseURL: context.profile.baseURL, trust: ClientFactory.trustPolicy(for: context.profile))
        defer { connection.session.finishTasksAndInvalidate() }
        let output: Operations.ExchangeSsoCode.Output
        do {
            output = try await connection.client.exchangeSsoCode(body: .json(.init(code: code, codeVerifier: verifier)))
        } catch {
            throw APIError.from(error)
        }
        switch output {
        case .ok(let ok): try completeSignIn(context: context, pair: ok.body.json)
        case .unauthorized(let r): throw APIError(try r.body.json, statusCode: 401)
        case .unprocessableContent(let r): throw APIError(try r.body.json, statusCode: 422)
        case .default(let status, let r): throw APIError(try r.body.json, statusCode: status)
        }
    }

    private func completeSignIn(context: LoginContext, pair: Components.Schemas.TokenPair) throws {
        let tokens = Tokens(accessToken: pair.accessToken, refreshToken: pair.refreshToken, expiresAt: pair.expiresAt)
        // Wechsel auf eine andere Installation: alles vom vorherigen System entfernen.
        if let previous = try? store.loadProfile(), previous.instanceId != context.profile.instanceId {
            try? store.wipe()
            try? instanceCache.wipeAll()
        }
        try store.saveProfile(context.profile)
        try store.saveTokens(tokens, instanceId: context.profile.instanceId)
        activate(profile: context.profile, tokens: tokens, system: context.system)
        Task { await refreshSignedInInfo() }
    }

    // MARK: Angemeldet

    private func activate(profile: ConnectionProfile, tokens: Tokens, system: SystemInfo? = nil) {
        connection?.invalidate()
        let trust = ClientFactory.trustPolicy(for: profile)
        let store = self.store
        let instanceId = profile.instanceId

        // Eigener Client ohne Auth-Middleware für den Refresh (sonst Rekursion).
        let refreshConnection = ClientFactory.makeConnection(baseURL: profile.baseURL, trust: trust)
        let manager = TokenManager(
            tokens: tokens,
            refresher: { refreshToken in
                let output = try await refreshConnection.client.refreshToken(body: .json(.init(refreshToken: refreshToken)))
                switch output {
                case .ok(let ok):
                    let pair = try ok.body.json
                    return Tokens(accessToken: pair.accessToken, refreshToken: pair.refreshToken, expiresAt: pair.expiresAt)
                case .unauthorized:
                    throw AuthError.notAuthenticated
                case .default(let status, let r):
                    // z. B. 503 im Edge-Verbund: Tokens behalten, NICHT abmelden.
                    throw (try? APIError(r.body.json, statusCode: status)) ?? APIError.unexpected(statusCode: status)
                }
            },
            persist: { tokens in
                if let tokens {
                    try? store.saveTokens(tokens, instanceId: instanceId)
                } else {
                    try? store.deleteTokens(instanceId: instanceId)
                }
            },
            onSessionExpired: { [weak self] in
                Task { @MainActor in await self?.sessionExpired() }
            }
        )
        let connection = ClientFactory.makeConnection(
            baseURL: profile.baseURL,
            trust: trust,
            middlewares: [AuthMiddleware(tokens: manager)]
        )
        self.connection = connection
        self.tokenManager = manager
        phase = .signedIn(SignedInContext(
            profile: profile,
            client: connection.client,
            previews: PreviewLoader(
                client: connection.client,
                cache: PreviewCache(directory: instanceCache.directory(for: profile.instanceId))
            ),
            system: system,
            me: nil
        ))
    }

    /// Lädt `/system` und `/me` nach (Fehler werden ignoriert, z. B. offline).
    public func refreshSignedInInfo() async {
        guard case .signedIn(var context) = phase else { return }
        if let system = try? await context.client.getSystem().ok.body.json {
            context.system = SystemInfo(system)
        }
        if let me = try? await context.client.getMe().ok.body.json {
            context.me = me
        }
        // Nur übernehmen, wenn inzwischen nicht gewechselt wurde.
        if case .signedIn(let current) = phase, current.profile == context.profile {
            phase = .signedIn(context)
        }
    }

    private func sessionExpired() async {
        guard case .signedIn(let context) = phase else { return }
        connection?.invalidate()
        connection = nil
        tokenManager = nil
        try? store.deleteTokens(instanceId: context.profile.instanceId)
        notice = L("Deine Anmeldung ist abgelaufen. Bitte melde dich erneut an.")
        phase = .starting
        await prepareLogin(profile: context.profile)
        if case .starting = phase { phase = .onboarding }
    }

    // MARK: Abmelden / System wechseln

    /// Laufende Anfragen abbrechen → `POST /auth/logout` (best effort) → Tokens, Cache, Profil löschen → Onboarding.
    public func signOut() async {
        let oldConnection = connection
        let manager = tokenManager
        connection = nil
        tokenManager = nil
        oldConnection?.session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }

        if case .signedIn(let context) = phase, let refreshToken = await manager?.currentRefreshToken {
            // Logout mit Refresh-Token im Body – funktioniert auch mit abgelaufenem Access-Token.
            let logoutConnection = ClientFactory.makeConnection(
                baseURL: context.profile.baseURL,
                trust: ClientFactory.trustPolicy(for: context.profile)
            )
            _ = try? await withTimeout(seconds: 5) {
                try await logoutConnection.client.logout(body: .json(.init(refreshToken: refreshToken)))
            }
            logoutConnection.invalidate()
        }
        oldConnection?.invalidate()

        try? store.wipe()
        try? instanceCache.wipeAll()
        phase = .onboarding
    }

    static let platform = "ios"

    /// Liefert den Wert der Erfolgsantwort oder wirft den Vertragsfehler als `APIError`.
    static func require<Output, Value>(_ output: Output, _ extract: (Output) throws -> Value) throws -> Value {
        try expect(output, extract)
    }

    /// Zurück ins Onboarding, ohne ein bestehendes Profil anzutasten (Abbruch auf der Anmeldeseite).
    public func cancelLogin() {
        if case .login = phase { phase = .onboarding }
    }
}
