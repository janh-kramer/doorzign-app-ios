import Foundation

/// Fehler rund um die Anmeldung.
public enum AuthError: Error, Equatable, Sendable {
    /// Keine gültigen Zugangsdaten (mehr) vorhanden – zurück zur Anmeldung.
    case notAuthenticated
}

/// Verwaltet das Tokenpaar einer Installation und serialisiert Refreshes:
/// Laufen mehrere Anfragen gleichzeitig in ein abgelaufenes Token, wird genau ein
/// `POST /auth/refresh` ausgeführt, alle anderen warten auf dessen Ergebnis.
public actor TokenManager {
    public typealias Refresher = @Sendable (_ refreshToken: String) async throws -> Tokens

    private var tokens: Tokens?
    private var refreshTask: Task<Tokens, Error>?
    private let refresher: Refresher
    private let persist: @Sendable (Tokens?) -> Void
    private let onSessionExpired: @Sendable () -> Void
    /// Vorlauf, ab dem ein Token schon vor dem Ablauf erneuert wird.
    private let leeway: TimeInterval

    public init(
        tokens: Tokens?,
        leeway: TimeInterval = 30,
        refresher: @escaping Refresher,
        persist: @escaping @Sendable (Tokens?) -> Void,
        onSessionExpired: @escaping @Sendable () -> Void
    ) {
        self.tokens = tokens
        self.leeway = leeway
        self.refresher = refresher
        self.persist = persist
        self.onSessionExpired = onSessionExpired
    }

    public var hasTokens: Bool { tokens != nil }

    public func set(_ newTokens: Tokens?) {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = newTokens
        persist(newTokens)
    }

    public var currentRefreshToken: String? { tokens?.refreshToken }

    /// Gültiges Access-Token; erneuert vorab, wenn es demnächst abläuft.
    public func validAccessToken(now: Date = Date()) async throws -> String {
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        guard let tokens else { throw AuthError.notAuthenticated }
        if tokens.expiresAt.timeIntervalSince(now) > leeway {
            return tokens.accessToken
        }
        return try await refresh(rejectedAccessToken: tokens.accessToken)
    }

    /// Das Backend hat das Token als widerrufen/ungültig abgelehnt (401 ≠ `token_expired`).
    /// Ist inzwischen ein anderes Token aktiv (paralleler Refresh), passiert nichts.
    public func invalidate(rejectedAccessToken: String) {
        guard refreshTask == nil, let tokens, tokens.accessToken == rejectedAccessToken else { return }
        self.tokens = nil
        persist(nil)
        onSessionExpired()
    }

    /// Erneuert das Token, nachdem `rejectedAccessToken` mit 401 abgelehnt wurde.
    /// Wurde inzwischen bereits erneuert, wird ohne weiteren Request das neue Token geliefert.
    @discardableResult
    public func refresh(rejectedAccessToken: String) async throws -> String {
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        guard let tokens else { throw AuthError.notAuthenticated }
        if tokens.accessToken != rejectedAccessToken {
            return tokens.accessToken
        }

        let refresher = self.refresher
        let refreshToken = tokens.refreshToken
        let task = Task { try await refresher(refreshToken) }
        refreshTask = task
        do {
            let fresh = try await task.value
            // Während des Refreshs abgemeldet? Dann das Ergebnis verwerfen.
            if refreshTask == task {
                self.tokens = fresh
                persist(fresh)
                refreshTask = nil
            }
            return fresh.accessToken
        } catch {
            if refreshTask == task {
                refreshTask = nil
                if case AuthError.notAuthenticated = error {
                    self.tokens = nil
                    persist(nil)
                    onSessionExpired()
                }
            }
            throw error
        }
    }
}
