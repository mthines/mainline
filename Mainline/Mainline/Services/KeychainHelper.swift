import Foundation
import Security

/// Minimal Keychain wrapper for storing the GitHub PAT.
/// Service: "com.mainline.github-pr-notifier"
/// Account: "github-pat"
/// Class:   kSecClassGenericPassword
enum KeychainHelper {
    private static let service = "com.mainline.github-pr-notifier"
    private static let account = "github-pat"
    /// Account for the optional Linear personal API key — used to resolve the
    /// Linear issue linked to a PR when the branch carries no derivable id.
    private static let linearAccount = "linear-api-key"

    // MARK: - GitHub token (public API — existing call sites unchanged)

    /// Saves or updates the GitHub token in the Keychain.
    static func saveToken(_ token: String) throws { try save(token, account: account) }

    /// Loads the GitHub token asynchronously. Returns nil if none is stored.
    static func loadToken() async -> String? { await load(account: account) }

    /// Removes the stored GitHub token.
    static func deleteToken() throws { try delete(account: account) }

    // MARK: - Linear API key

    /// Saves or updates the Linear personal API key in the Keychain.
    static func saveLinearKey(_ key: String) throws { try save(key, account: linearAccount) }

    /// Loads the Linear API key asynchronously. Returns nil if none is stored.
    static func loadLinearKey() async -> String? { await load(account: linearAccount) }

    /// Removes the stored Linear API key.
    static func deleteLinearKey() throws { try delete(account: linearAccount) }

    // MARK: - Save

    /// Saves or updates a secret for the given account.
    private static func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
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

    /// Loads a secret asynchronously from the Keychain. Returns nil if none stored.
    private static func load(account: String) async -> String? {
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

    /// Removes the stored secret for the given account.
    private static func delete(account: String) throws {
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
