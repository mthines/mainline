import Foundation
import Security

/// Minimal Keychain wrapper for storing the GitHub PAT.
/// Service: "com.mainline.github-pr-notifier"
/// Account: "github-pat"
/// Class:   kSecClassGenericPassword
enum KeychainHelper {
    private static let service = "com.mainline.github-pr-notifier"
    private static let account = "github-pat"

    // MARK: - Save

    /// Saves or updates the token in the Keychain.
    static func saveToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account,
        ]

        let attributes: [CFString: Any] = [
            kSecValueData: data
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Load (async — never blocks MainActor)

    /// Loads the token asynchronously from the Keychain.
    /// Returns nil if no token is stored.
    static func loadToken() async -> String? {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let query: [CFString: Any] = [
                    kSecClass:       kSecClassGenericPassword,
                    kSecAttrService: service,
                    kSecAttrAccount: account,
                    kSecReturnData:  kCFBooleanTrue!,
                    kSecMatchLimit:  kSecMatchLimitOne,
                ]

                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)

                if status == errSecSuccess,
                   let data = result as? Data,
                   let token = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Delete

    /// Removes the stored token from the Keychain.
    static func deleteToken() throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Error

    enum KeychainError: Error, LocalizedError {
        case encodingFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Failed to encode token as UTF-8 data."
            case .unexpectedStatus(let status):
                return "Keychain operation failed with status: \(status)"
            }
        }
    }
}
