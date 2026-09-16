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

    /// Outcome of a single Keychain read, kept distinct so the cache can tell a
    /// *definitive* answer (the token, or a confirmed absence) apart from a
    /// *transient failure* (a denied ACL prompt, `errSecInteractionNotAllowed`,
    /// …). Only the first two are safe to cache; a failure must be retried.
    private enum TokenLoadResult {
        /// A token was read successfully.
        case found(String)
        /// The item does not exist (`errSecItemNotFound`), or exists but is
        /// unreadable — a deterministic "no usable token", safe to cache as nil.
        case absent
        /// The read failed for a transient reason (ACL denied, interaction not
        /// allowed, …). NOT cached — the next caller retries.
        case failed

        /// The token to hand back to callers; nil for both `.absent` and `.failed`.
        var token: String? {
            if case .found(let token) = self { return token }
            return nil
        }
    }

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
        private var inFlight: Task<TokenLoadResult, Never>?
        /// Bumped by every `store`/`invalidate`. A load captures it before the
        /// `await` and only commits its result if it is unchanged afterwards, so a
        /// write that lands *during* the load is authoritative and is never
        /// clobbered by the resuming (now-stale) read — actors are re-entrant
        /// across `await`, so this guard is load-bearing, not defensive.
        private var generation = 0

        /// Returns the cached token, loading it once via `loader` on a miss and
        /// coalescing concurrent misses onto a single load.
        ///
        /// A `.failed` load is deliberately NOT cached: before this cache existed
        /// every `loadToken()` re-read the Keychain, so a denied ACL prompt healed
        /// on the next ~30s poll. Pinning `loaded` on a failure would strand every
        /// caller signed-out until relaunch — a regression in exactly the scenario
        /// this cache exists to smooth. So only `.found`/`.absent` set `loaded`.
        func token(loader: @Sendable @escaping () async -> TokenLoadResult) async -> String? {
            if loaded { return value }
            if let inFlight { return await inFlight.value.token }
            let gen = generation
            let task = Task { await loader() }
            inFlight = task
            let result = await task.value
            // Only commit if no store()/invalidate() ran during the load.
            if generation == gen {
                inFlight = nil
                switch result {
                case .found(let token):
                    loaded = true
                    value = token
                case .absent:
                    loaded = true
                    value = nil
                case .failed:
                    // Leave `loaded` false so the next caller retries.
                    break
                }
            }
            return result.token
        }

        /// Seeds the cache with a known value (e.g. just after saving a new token),
        /// so the next read serves it without touching the Keychain.
        func store(_ newValue: String?) {
            loaded = true
            value = newValue
            inFlight = nil
            generation += 1
        }

        /// Forgets the cached value so the next read reloads from the Keychain.
        func invalidate() {
            loaded = false
            value = nil
            inFlight = nil
            generation += 1
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

    /// Loads a secret asynchronously from the Keychain, distinguishing a
    /// definitive answer (`.found` / `.absent`) from a transient failure
    /// (`.failed`) so the cache knows which results are safe to keep.
    private static func load(account: String) async -> TokenLoadResult {
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

                switch status {
                case errSecSuccess:
                    if let data = result as? Data,
                       let token = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: .found(token))
                    } else {
                        // Present but unreadable — a corrupt entry, not a transient
                        // error. Cache as absent so we don't re-read (and risk
                        // re-prompting) on every call.
                        continuation.resume(returning: .absent)
                    }
                case errSecItemNotFound:
                    continuation.resume(returning: .absent)
                default:
                    // errSecInteractionNotAllowed, a denied/failed ACL prompt, etc.
                    // Transient: don't let the cache pin this as "no token".
                    continuation.resume(returning: .failed)
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
