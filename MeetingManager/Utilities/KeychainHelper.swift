import Foundation
import Security

/// Provides generic save, load, and delete operations for keychain items
/// using `kSecClassGenericPassword`.
enum KeychainHelper {

    /// Well-known keychain keys used throughout the app.
    enum Key {
        static let claudeAPIKey = "claude-api-key"
        static let googleOAuthToken = "google-oauth-token"
        /// User-supplied Google OAuth client ID (not secret — PKCE native apps have no secret).
        static let googleOAuthClientId = "google-oauth-client-id"
    }

    /// The service identifier written into every keychain item.
    private static let service = "com.meetingmanager"

    // MARK: - Errors

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
        case encodingFailed
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Keychain save failed with status \(status)"
            case .loadFailed(let status):
                return "Keychain load failed with status \(status)"
            case .deleteFailed(let status):
                return "Keychain delete failed with status \(status)"
            case .encodingFailed:
                return "Failed to encode value for keychain storage"
            case .decodingFailed:
                return "Failed to decode value from keychain"
            }
        }
    }

    // MARK: - String Helpers

    /// Saves a string value to the keychain under the given key.
    static func save(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try save(data: data, forKey: key)
    }

    /// Loads a string value from the keychain for the given key.
    /// Returns `nil` when the item does not exist.
    static func loadString(forKey key: String) throws -> String? {
        guard let data = try loadData(forKey: key) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }

    // MARK: - Codable Helpers

    /// Saves a `Codable` value to the keychain under the given key.
    static func save<T: Codable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        try save(data: data, forKey: key)
    }

    /// Loads a `Codable` value from the keychain for the given key.
    /// Returns `nil` when the item does not exist.
    static func load<T: Codable>(forKey key: String) throws -> T? {
        guard let data = try loadData(forKey: key) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Delete

    /// Deletes the keychain item for the given key.
    /// No error is thrown if the item does not exist.
    static func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Private

    private static func save(data: Data, forKey key: String) throws {
        // Remove any existing item first.
        try? delete(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private static func loadData(forKey key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }
        return result as? Data
    }
}
