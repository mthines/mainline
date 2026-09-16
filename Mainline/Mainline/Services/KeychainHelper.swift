import Foundation
import Security

/// Minimal Keychain wrapper for storing the GitHub PAT.
/// Service: "com.mainline.github-pr-notifier"
/// Account: "github-pat"
/// Class:   kSecClassGenericPassword
enum KeychainHelper {
    private static let service = "com.mainline.github-pr-notifier"
    private static let account = "github-pat"

    // MARK: - In-memory token cache

    /// Serialises access to the cached GitHub token so the Keychain is read **once
    /// per launch**, not once per caller.
    ///
    /// Every `SecItemCopyMatching` can raise a macOS Keychain-access prompt when the
    /// running binary is not (yet) on the item's ACL — which is exactly the state
    /// right after an app update re-signs the binary. Without a cache, each of the
    /// many independent `loadToken()` sites (the poll loop, pin fetches, search,
    /// peek, write actions) prompts separately, and a recurring caller like the
    /// pin-fetch refresh re-prompts every poll. Reading once and serving the rest
    /// from memory collapses that to a single prompt per launch (and none after the
    /// user picks "Always Allow" on a stably-signed release).
    ///
    /// Concurrent first-loads are coalesced into ONE Keychain read via `inFlight`,
    /// so the poll, a search, and a pin fetch racing at launch don't each prompt.
    private actor TokenCache {
        private var loaded = false
        private var value: String?
        private var inFlight: Task<String?, Never>?

        /// Returns the cached token, loading it once via `loader` on a miss and
        /// coalescing concurrent misses onto a single load.
        func token(loader: @Sendable @escaping () async -> String?) async -> String? {
            if loaded { return value }
            if let inFlight { return await inFlight.value }
            let task = Task { await loader() }
            inFlight = task
            let result = await task.value
            loaded = true
            value = result
            inFlight = nil
            return result
        }

        /// Seeds the cache with a known value (e.g. just after saving a new token),
        /// so the next read serves it without touching the Keychain.
        func store(_ newValue: String?) {
            loaded = true
            value = newValue
            inFlight = nil
        }

        /// Forgets the cached value so the next read reloads from the Keychain.
        func invalidate() {
            loaded = false
            value = nil
            inFlight = nil
        }
    }

    private static let tokenCache = TokenCache()

    // MARK: - GitHub token (public API — existing call sites unchanged)

    /// Saves or updates the GitHub token in the Keychain, and seeds the in-memory
    /// cache so subsequent `loadToken()` calls this launch never re-read (and never
    /// re-prompt).
    static func saveToken(_ token: String) throws {
        try save(token, account: account)
        Task { await tokenCache.store(token) }
    }

    /// Loads the GitHub token, served from the in-memory cache after the first read
    /// this launch. Returns nil if none is stored.
    static func loadToken() async -> String? {
        await tokenCache.token { await load(account: account) }
    }

    /// Removes the stored GitHub token and clears the cache.
    static func deleteToken() throws {
        try delete(account: account)
        Task { await tokenCache.invalidate() }
    }

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
