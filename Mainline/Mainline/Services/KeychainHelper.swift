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

    // MARK: - Cache self-checks (DEBUG)

    #if DEBUG
    /// One-shot async gate used only by the concurrency self-check below. Safe by
    /// construction: `signal()` is idempotent and is always called, so `wait()`
    /// can never deadlock.
    private actor SelfCheckGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func signal() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Exercises `TokenCache` correctness against a stubbed loader, so the real
    /// Keychain is never touched — `token(loader:)` takes an injectable loader
    /// precisely so this is possible. Covers the sequential state machine (a
    /// `.failed` load is retried; `.found`/`.absent` are cached; `store` seeds;
    /// `invalidate` reloads) AND the concurrent generation guard (a `store`
    /// landing mid-load wins over the resuming read). Mirrors the pure-logic
    /// self-checks elsewhere (`InboxMuteEngine`, `PRSearchFilter`, …); invoked
    /// once at launch from `applicationDidFinishLaunching`. Async because the
    /// actor is, so it runs in its own detached task — assertions still trip a
    /// DEBUG build without a full XCTest target.
    static func runCacheSelfChecks() {
        Task {
            // A `.failed` load must NOT be cached: the next read retries and can
            // succeed. This is the blocking regression the cache shipped with.
            let retry = TokenCache()
            let first = await retry.token { .failed }
            assert(first == nil, "a failed load returns nil")
            let second = await retry.token { .found("tok") }
            assert(second == "tok", "after a failed load, the next read retries and succeeds")

            // `.absent` IS definitive and cached: a later loader is never consulted.
            let absent = TokenCache()
            _ = await absent.token { .absent }
            let afterAbsent = await absent.token { .found("unread") }
            assert(afterAbsent == nil, "absent is cached; the loader is not re-consulted")

            // `.found` is cached too.
            let found = TokenCache()
            _ = await found.token { .found("cached") }
            let afterFound = await found.token { .found("unread") }
            assert(afterFound == "cached", "found is cached; the loader is not re-consulted")

            // `store` seeds the cache and short-circuits the loader.
            let seeded = TokenCache()
            await seeded.store("seeded")
            let afterStore = await seeded.token { .found("unread") }
            assert(afterStore == "seeded", "store seeds the cache; the loader is not consulted")

            // `invalidate` forces the next read to reload.
            let invalidated = TokenCache()
            _ = await invalidated.token { .found("old") }
            await invalidated.invalidate()
            let afterInvalidate = await invalidated.token { .found("new") }
            assert(afterInvalidate == "new", "invalidate forces a reload")

            // Generation guard: a `store()` that lands WHILE a load is in flight
            // must win — the resuming, now-stale read must not clobber it. This is
            // deterministic: the loader signals once it has begun (so `token` has
            // captured the generation and set `inFlight`) and parks until released,
            // and actor serialisation guarantees `store()` runs only while `token`
            // is suspended at `await task.value`.
            let race = TokenCache()
            let started = SelfCheckGate()
            let release = SelfCheckGate()
            let load = Task {
                await race.token {
                    await started.signal()
                    await release.wait()
                    return .found("stale")
                }
            }
            await started.wait()        // the load has begun; generation captured
            await race.store("fresh")   // lands during the load → bumps generation
            await release.signal()      // let the load resume and lose the commit
            _ = await load.value
            let winner = await race.token { .found("unread") }
            assert(winner == "fresh",
                   "a store during the load wins; the resuming read does not clobber it")
        }
    }
    #endif
}
