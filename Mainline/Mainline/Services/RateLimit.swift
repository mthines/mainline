import Foundation

// MARK: - Pure classification

/// One observed GitHub rate-limit hit: when it lifts, and which limit it was.
struct RateLimitHit: Equatable {
    enum Kind: String, Equatable {
        /// The hourly points/requests budget ran out (`X-RateLimit-Remaining: 0`).
        case primary
        /// GitHub's abuse protection (`Retry-After`, or a 403 body that says so).
        case secondary
    }
    let resetAt: Date
    let kind: Kind
    /// The exhausted budget (`core`, `graphql`, `search`…) for a primary limit; nil for a
    /// secondary limit, which throttles the whole app. REST and GraphQL have separate
    /// hourly budgets, so an empty REST budget must not pause GraphQL polling.
    var resource: String? = nil

    /// The key `RateLimitMonitor` stores this hit under.
    var key: String { resource ?? RateLimitMonitor.appWide }
}

/// Decides whether a response IS a rate limit. Pure, so `RateLimitChecks` can assert
/// every shape without the network.
///
/// GitHub signals a limit four different ways, and only two of them were handled
/// before: 429, and any response with `X-RateLimit-Remaining: 0`. Missing were a
/// secondary limit (403 + `Retry-After`, `Remaining` > 0 — the usual "stopped
/// updating" culprit) and a GraphQL limit (HTTP 200, `errors[].type == RATE_LIMITED`).
/// Meanwhile a *successful* 200 whose `Remaining` happened to be 0 was thrown away.
enum RateLimitClassifier {
    static let defaultSecondaryWait = 60
    static let maxWait = 3600

    /// - Parameter header: case-insensitive header lookup (`HTTPURLResponse.value`).
    static func classify(
        status: Int,
        header: (String) -> String?,
        body: Data?,
        resourceFallback: String = "core",
        now: Date = Date()
    ) -> RateLimitHit? {
        let remaining = header("X-RateLimit-Remaining")
        let retryAfter = header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let reset = header("X-RateLimit-Reset").flatMap { TimeInterval($0) }

        let resource = header("X-RateLimit-Resource") ?? resourceFallback
        func hit(_ seconds: Int, _ kind: RateLimitHit.Kind) -> RateLimitHit {
            RateLimitHit(
                resetAt: now.addingTimeInterval(TimeInterval(min(max(seconds, 1), maxWait))),
                kind: kind,
                resource: kind == .primary ? resource : nil
            )
        }
        func untilReset() -> Int? { reset.map { Int(max($0 - now.timeIntervalSince1970, 1).rounded(.up)) } }

        switch status {
        case 429, 403:
            if remaining == "0", let wait = untilReset() { return hit(wait, .primary) }
            if let retryAfter { return hit(retryAfter, .secondary) }
            if status == 429 { return hit(defaultSecondaryWait, .secondary) }
            // A plain 403 is usually a real permission error; only the body can tell.
            if let body, let text = String(data: body.prefix(2048), encoding: .utf8),
               text.lowercased().contains("rate limit") {
                return hit(defaultSecondaryWait, .secondary)
            }
            return nil
        case 200:
            guard let body, graphQLRateLimited(body: body) else { return nil }
            // Budget left means this is abuse protection, not the hourly reset — a
            // short wait, not the up-to-an-hour `X-RateLimit-Reset`.
            if remaining == "0", let wait = untilReset() {
                return RateLimitHit(resetAt: hit(wait, .primary).resetAt, kind: .primary, resource: "graphql")
            }
            return hit(retryAfter ?? defaultSecondaryWait, .secondary)
        default:
            return nil
        }
    }

    /// GraphQL reports an exhausted budget as HTTP 200 + `errors[].type == "RATE_LIMITED"`.
    /// A cheap byte search gates the decode so ordinary (large) bodies are never parsed here.
    static func graphQLRateLimited(body: Data) -> Bool {
        guard body.range(of: Data("RATE_LIMITED".utf8)) != nil else { return false }
        struct Envelope: Decodable {
            struct E: Decodable { let type: String? }
            let errors: [E]?
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: body) else { return false }
        return env.errors?.contains { $0.type == "RATE_LIMITED" } ?? false
    }

    /// "19:42" — the wall-clock time a limit lifts.
    static func clockLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Shared monitor

/// The one place every GitHub request reports a limit and asks whether it may go out.
///
/// `PRManager` and `PRPoller` each own a `GitHubClient`, so per-client state would
/// split; this singleton is shared. Requests are refused (`GitHubClient.performRequest`)
/// while a limit is active, so a limited app stops hammering the API — which would
/// extend a secondary limit — and the popover can say so instead of silently freezing.
final class RateLimitMonitor: ObservableObject, @unchecked Sendable {
    static let shared = RateLimitMonitor()

    /// The limit being waited out, kept until a poll fully succeeds (so the banner can
    /// say "retrying…" once `resetAt` passes). Published on the main thread.
    @Published private(set) var active: RateLimitHit?

    /// Key for hits that throttle every request (secondary limits).
    static let appWide = "*"
    /// The budget the PR/issue polls draw on.
    static let pollResource = "graphql"

    private let lock = NSLock()
    private var blocked: [String: RateLimitHit] = [:]
    /// Last hit that affects polling (app-wide or `graphql`) — a `core`-only hit must
    /// not stop a healthy poll from clearing the banner.
    private var lastPollingReportAt: Date?

    /// The hit still in the future that stops a request on `resource`: an app-wide
    /// hit or one on that very budget. nil once lifted. Thread-safe.
    func blockedHit(for resource: String) -> RateLimitHit? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return [blocked[Self.appWide], blocked[resource]]
            .compactMap { $0 }
            .filter { $0.resetAt > now }
            .max { $0.resetAt < $1.resetAt }
    }

    /// Records a hit from any thread. A later reset wins over an earlier one.
    func report(_ hit: RateLimitHit) {
        lock.lock()
        if let current = blocked[hit.key], current.resetAt > hit.resetAt {
            // keep the later reset
        } else {
            blocked[hit.key] = hit
        }
        if hit.key == Self.appWide || hit.key == Self.pollResource { lastPollingReportAt = Date() }
        lock.unlock()
        publish()
    }

    /// A poll fully succeeded — polling's limit is over. `pollStartedAt` is when that
    /// poll began: a hit reported DURING it (a swallowed `try?` request, or another
    /// client) is newer than the poll's evidence of health and must survive.
    func clear(ifNoHitSince pollStartedAt: Date) {
        lock.lock()
        if let last = lastPollingReportAt, last >= pollStartedAt {
            lock.unlock()
            return
        }
        blocked[Self.appWide] = nil
        blocked[Self.pollResource] = nil
        lock.unlock()
        publish()
    }

    /// Re-reads the state on the main thread, so racing report/clear calls can never
    /// leave `active` disagreeing with `blocked`. Only limits that affect polling are
    /// shown: an empty REST budget alone does not pause anything the banner describes.
    private func publish() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = [self.blocked[Self.appWide], self.blocked[Self.pollResource]]
                .compactMap { $0 }
                .max { $0.resetAt < $1.resetAt }
            self.lock.unlock()
            if self.active != current { self.active = current }
        }
    }
}

#if DEBUG
enum RateLimitChecks {
    static func run() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func h(_ d: [String: String]) -> (String) -> String? { { d[$0] } }
        func secs(_ x: RateLimitHit?) -> Int? { x.map { Int($0.resetAt.timeIntervalSince(now)) } }

        // 429 with and without Retry-After
        assert(secs(RateLimitClassifier.classify(status: 429, header: h(["Retry-After": "30"]), body: nil, now: now)) == 30)
        assert(secs(RateLimitClassifier.classify(status: 429, header: h([:]), body: nil, now: now)) == 60)
        // Secondary: 403 + Retry-After, Remaining still > 0 (previously fell to unknown(403))
        let sec = RateLimitClassifier.classify(status: 403, header: h(["Retry-After": "45", "X-RateLimit-Remaining": "100"]), body: nil, now: now)
        assert(sec?.kind == .secondary && secs(sec) == 45)
        // Primary: 403 + Remaining 0 + reset
        let pri = RateLimitClassifier.classify(status: 403, header: h(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000120"]), body: nil, now: now)
        assert(pri?.kind == .primary && secs(pri) == 120)
        // Plain 403 is a permission error, not a limit
        assert(RateLimitClassifier.classify(status: 403, header: h([:]), body: Data("Resource not accessible".utf8), now: now) == nil)
        // 403 whose body names a secondary limit
        assert(RateLimitClassifier.classify(status: 403, header: h([:]), body: Data("You have exceeded a secondary rate limit".utf8), now: now)?.kind == .secondary)
        // A successful 200 with Remaining 0 is NOT thrown away
        assert(RateLimitClassifier.classify(status: 200, header: h(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000120"]), body: Data(#"{"data":{}}"#.utf8), now: now) == nil)
        // GraphQL limit at HTTP 200 with budget left: short secondary wait, not the hourly reset
        assert(secs(RateLimitClassifier.classify(status: 200, header: h(["X-RateLimit-Remaining": "4000", "X-RateLimit-Reset": "1003000"]), body: Data(#"{"errors":[{"type":"RATE_LIMITED"}]}"#.utf8), now: now)) == 60)
        // GraphQL limit at HTTP 200
        let gql = Data(#"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#.utf8)
        assert(RateLimitClassifier.classify(status: 200, header: h(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000090"]), body: gql, now: now)?.kind == .primary)
        // The marker inside ordinary content (a PR title) is not a limit
        assert(!RateLimitClassifier.graphQLRateLimited(body: Data(#"{"data":{"title":"RATE_LIMITED handling"}}"#.utf8)))
        // REST budget exhausted names `core`; it must not be app-wide
        let core = RateLimitClassifier.classify(status: 403, header: h(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000120", "X-RateLimit-Resource": "core"]), body: nil, now: now)
        assert(core?.resource == "core" && core?.key == "core")
        // Secondary limits are app-wide
        assert(sec?.resource == nil && sec?.key == RateLimitMonitor.appWide)
        // Waits are clamped to [1, maxWait]
        assert(secs(RateLimitClassifier.classify(status: 429, header: h(["Retry-After": "999999"]), body: nil, now: now)) == RateLimitClassifier.maxWait)
    }
}
#endif
