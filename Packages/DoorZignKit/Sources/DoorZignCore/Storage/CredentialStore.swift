import Foundation

/// Tokenpaar eines Geräts.
public struct Tokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Persistenz von Profil und Tokens. Tokens sind pro `instanceId` abgelegt, damit nie
/// Zugangsdaten eines anderen Systems verwendet werden.
public protocol CredentialStoring: Sendable {
    func loadProfile() throws -> ConnectionProfile?
    func saveProfile(_ profile: ConnectionProfile) throws
    func loadTokens(instanceId: String) throws -> Tokens?
    func saveTokens(_ tokens: Tokens, instanceId: String) throws
    func deleteTokens(instanceId: String) throws
    /// Entfernt Profil und alle Tokens.
    func wipe() throws
}

public struct KeychainCredentialStore: CredentialStoring {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    private static let profileAccount = "profile"
    private static func tokenAccount(_ instanceId: String) -> String { "tokens.\(instanceId)" }

    public func loadProfile() throws -> ConnectionProfile? {
        try keychain.value(ConnectionProfile.self, for: Self.profileAccount)
    }

    public func saveProfile(_ profile: ConnectionProfile) throws {
        try keychain.setValue(profile, for: Self.profileAccount)
    }

    public func loadTokens(instanceId: String) throws -> Tokens? {
        try keychain.value(Tokens.self, for: Self.tokenAccount(instanceId))
    }

    public func saveTokens(_ tokens: Tokens, instanceId: String) throws {
        try keychain.setValue(tokens, for: Self.tokenAccount(instanceId))
    }

    public func deleteTokens(instanceId: String) throws {
        try keychain.delete(Self.tokenAccount(instanceId))
    }

    public func wipe() throws {
        try keychain.deleteAll()
    }
}

/// Speicher im Arbeitsspeicher, für Tests und SwiftUI-Previews.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: ConnectionProfile?
    private var tokens: [String: Tokens] = [:]

    public init(profile: ConnectionProfile? = nil) {
        self.profile = profile
    }

    public func loadProfile() throws -> ConnectionProfile? { lock.withLock { profile } }
    public func saveProfile(_ profile: ConnectionProfile) throws { lock.withLock { self.profile = profile } }
    public func loadTokens(instanceId: String) throws -> Tokens? { lock.withLock { tokens[instanceId] } }
    public func saveTokens(_ tokens: Tokens, instanceId: String) throws { lock.withLock { self.tokens[instanceId] = tokens } }
    public func deleteTokens(instanceId: String) throws { lock.withLock { _ = tokens.removeValue(forKey: instanceId) } }
    public func wipe() throws { lock.withLock { profile = nil; tokens = [:] } }
}
