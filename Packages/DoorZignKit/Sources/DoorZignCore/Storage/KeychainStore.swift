import Foundation
import Security

/// Fehler beim Zugriff auf den Schlüsselbund.
public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Ablage im Schlüsselbund (generische Passwörter), nur auf diesem Gerät und erst nach dem ersten Entsperren lesbar.
/// Hier liegen Tokens und das Verbindungsprofil (enthält den gepinnten Fingerprint).
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "de.doorzign.app") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func data(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func set(_ data: Data, for account: String) throws {
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Löscht alle Einträge dieses Dienstes (Systemwechsel).
    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    // MARK: Codable-Helfer

    public func value<T: Decodable>(_ type: T.Type, for account: String) throws -> T? {
        guard let data = try data(for: account) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func setValue<T: Encodable>(_ value: T, for account: String) throws {
        try set(JSONEncoder().encode(value), for: account)
    }
}
