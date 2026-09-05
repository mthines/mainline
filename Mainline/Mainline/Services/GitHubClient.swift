import Foundation

// MARK: - Error Types

enum GitHubAPIError: Error, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: Int)   // seconds
    case notModified                    // 304 — no changes
    case cancelled                      // request cancelled (popover closed) — benign
    case serverError(Int)               // 5xx — transient GitHub server error; retry next poll
    case networkError(URLError)
    case decodingError(Error)
    case unknown(Int)                   // HTTP status code
    case actionFailed(String)           // GraphQL top-level errors on a mutation (HTTP 200, data:null)

    var errorDescription: String? {
        switch self {
        case .actionFailed(let message):
            return message
        case .unauthorized:
            return "GitHub token is invalid or expired."
        case .rateLimited(let seconds):
            return "GitHub rate limit hit. Retry after \(seconds)s."
        case .notModified:
            return "No changes since last poll."
        case .cancelled:
            return "Request cancelled."
        case .serverError(let code):
            return "GitHub server error (\(code)) — will retry."
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .decodingError(let err):
            return "Failed to decode GitHub response: \(err.localizedDescription)"
        case .unknown(let code):
            return "Unexpected HTTP status: \(code)"
        }
    }
}

// MARK: - Merge Method

/// The resolved GraphQL `PullRequestMergeMethod` actually sent to GitHub.
/// Distinct from `MergeMethodPreference` (the user's setting, which includes `.auto`).
enum GitHubMergeMethod {
    case merge
    case squash
    case rebase

    /// The GraphQL enum literal (`PullRequestMergeMethod`) sent as the `$method` variable.
    var graphQLValue: String {
        switch self {
        case .merge:  return "MERGE"
        case .squash: return "SQUASH"
        case .rebase: return "REBASE"
        }
    }
}

// MARK: - GraphQL Response Models (private to this file)

private struct GraphQLResponse: Decodable {
    let data: GraphQLData?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
    let type: String?
}

private struct GraphQLData: Decodable {
    let search: GraphQLSearch
}

private struct GraphQLSearch: Decodable {
    let nodes: [GraphQLNode]
}

/// A search node. Non-PR results decode to all-nil (we filter them out).
private struct GraphQLNode: Decodable {
    let id: String?
    let number: Int?
    let title: String?
    let url: String?
    let isDraft: Bool?
    let merged: Bool?
    let closed: Bool?
    let state: String?           // OPEN | CLOSED | MERGED
    let reviewDecision: String?  // APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null
    let updatedAt: String?
    let author: GraphQLActor?
    let repository: GraphQLRepository?
    let comments: GraphQLCountWithAuthors?
    let reviews: GraphQLCountWithAuthors?
    let commits: GraphQLCommits?
    // Triage Cockpit additions
    let mergeable: String?       // MERGEABLE | CONFLICTING | UNKNOWN
    let headRefName: String?
    let additions: Int?
    let deletions: Int?
    let reviewRequests: GraphQLReviewRequests?
    let reviewThreads: GraphQLReviewThreads?
    let labels: GraphQLLabels?
    let latestReviews: GraphQLLatestReviews?
}

/// The most recent review per author, from `latestReviews`. Used to determine
/// whether the authenticated viewer's own latest review is an approval.
private struct GraphQLLatestReviews: Decodable {
    let nodes: [GraphQLLatestReviewNode]
}

private struct GraphQLLatestReviewNode: Decodable {
    let state: String?               // APPROVED | CHANGES_REQUESTED | COMMENTED | ...
    let author: GraphQLTypedActor?
}

private struct GraphQLReviewThreads: Decodable {
    let nodes: [GraphQLReviewThreadNode]
}

private struct GraphQLReviewThreadNode: Decodable {
    let isResolved: Bool?
}

private struct GraphQLReviewRequests: Decodable {
    let nodes: [GraphQLReviewRequestNode]
}

private struct GraphQLReviewRequestNode: Decodable {
    let requestedReviewer: GraphQLRequestedReviewer?
}

/// A requested reviewer is either a User (has `login`) or a Team (has `slug`/`name`).
/// GraphQL inline fragments populate whichever applies.
private struct GraphQLRequestedReviewer: Decodable {
    let login: String?  // ... on User
    let slug: String?   // ... on Team
    let name: String?   // ... on Team
}

/// Response model for REST `/repos/{owner}/{repo}/issues/{number}/comments`.
/// Only the fields needed to find the preview-deployment comment and its body.
private struct IssueComment: Decodable {
    struct User: Decodable { let login: String? }
    let user: User?
    let body: String?
}

/// Response model for REST `/repos/{owner}/{repo}/pulls/{number}/files`.
struct PRFile: Decodable {
    let filename: String
    let additions: Int
    let deletions: Int
    /// GitHub file status: "added" | "modified" | "removed" | "renamed" | "changed".
    var status: String? = nil
}

/// PR author actor — now carries `__typename` so we can detect Bot authors
/// the same way review/comment authors are detected. The `CodingKeys` alias
/// maps the GraphQL `__typename` wire name.
private struct GraphQLActor: Decodable {
    let typename: String?
    let login: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
    }
}

/// Labels container decoded from `labels(first: 10) { nodes { name } }`.
private struct GraphQLLabels: Decodable {
    struct LabelNode: Decodable { let name: String? }
    let nodes: [LabelNode]
}

private struct GraphQLRepository: Decodable {
    let nameWithOwner: String
    let mergeCommitAllowed: Bool?
    let squashMergeAllowed: Bool?
    let rebaseMergeAllowed: Bool?
}

private struct GraphQLCount: Decodable {
    let totalCount: Int
}

/// Count plus the latest node's author, used to detect whether the most recent
/// comment/review was authored by a bot. `nodes` is fetched with `last: 1`.
private struct GraphQLCountWithAuthors: Decodable {
    let totalCount: Int
    let nodes: [GraphQLAuthoredNode]?
}

private struct GraphQLAuthoredNode: Decodable {
    let author: GraphQLTypedActor?
}

/// An actor carrying its GraphQL `__typename` (e.g. "Bot", "User") and login.
/// GitHub returns `__typename == "Bot"` for GitHub App / bot authors; app
/// committers also carry a login ending in `[bot]`.
private struct GraphQLTypedActor: Decodable {
    let typename: String?
    let login: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
    }
}

private struct GraphQLCommits: Decodable {
    let nodes: [GraphQLCommitNode]
}

private struct GraphQLCommitNode: Decodable {
    let commit: GraphQLCommit
}

private struct GraphQLCommit: Decodable {
    let statusCheckRollup: GraphQLRollup?
}

private struct GraphQLRollup: Decodable {
    let state: String  // SUCCESS | FAILURE | ERROR | PENDING | EXPECTED
}

// MARK: - GitHubClient

final class GitHubClient {
    private let session: URLSession
    private let settings: MainlineSettings

    init(settings: MainlineSettings = .shared) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Search PRs (GraphQL)

    /// Page size for the open-PR search. GitHub aborts a GraphQL request that
    /// exceeds its server-side time budget with a 5xx, and this document fans out
    /// per node (labels, comments, reviews, reviewRequests, reviewThreads, commits),
    /// so a full 100-node page sits right at that budget on large review queues.
    static let searchPageSize = 100

    /// Reduced page size used for the single retry after a 5xx. Halving the fan-out
    /// roughly halves the server-side work, so the retry usually completes inside
    /// the budget that the full-size request blew.
    static let searchPageSizeDegraded = 50

    /// Delay before the post-5xx retry, in nanoseconds.
    private static let searchRetryDelayNanos: UInt64 = 750_000_000

    /// Search for PRs matching `query` and tag the results with `tab`.
    /// GraphQL returns review decision + CI rollup in a single round trip, so
    /// no per-PR check-runs fan-out is needed.
    /// Throws `.notModified` if the server returned 304 (ETag unchanged).
    ///
    /// A 5xx is retried ONCE at `searchPageSizeDegraded` before being rethrown: the
    /// 5xx on this endpoint is overwhelmingly a server-side timeout on an expensive
    /// query, not an outage, so a smaller page is far more likely to succeed than an
    /// identical retry. Every other error (401, 304, rate limit, cancellation)
    /// propagates unchanged on the first attempt — only `.serverError` retries.
    func searchPRs(query: String, token: String, tab: ReviewTab) async throws -> (snapshots: [PRSnapshot], etag: String?) {
        do {
            return try await runSearch(
                query: query,
                token: token,
                tab: tab,
                first: Self.searchPageSize,
                etagPrefix: "graphql.search"
            )
        } catch GitHubAPIError.serverError(_) {
            try await Task.sleep(nanoseconds: Self.searchRetryDelayNanos)
            return try await runSearch(
                query: query,
                token: token,
                tab: tab,
                first: Self.searchPageSizeDegraded,
                etagPrefix: "graphql.search"
            )
        }
    }

    /// Shared GraphQL search executor backing both `searchPRs` (open, first: 100)
    /// and `searchDonePRs` (completed, first: 30). `etagPrefix` keeps the two
    /// caches distinct so an open 304 can't suppress a Done fetch (and vice versa).
    private func runSearch(
        query: String,
        token: String,
        tab: ReviewTab,
        first: Int,
        etagPrefix: String
    ) async throws -> (snapshots: [PRSnapshot], etag: String?) {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            throw GitHubAPIError.unknown(0)
        }

        let gql = Self.searchQueryDocument
        let variables: [String: Any] = ["q": query, "first": first]
        let bodyDict: [String: Any] = ["query": gql, "variables": variables]
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            throw GitHubAPIError.unknown(0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // ETag caching — keyed per prefix + tab + query + page size so the two tabs
        // (and the open vs. done fetches) never collide, and so a 304 earned by the
        // degraded retry page can't suppress the next full-size fetch.
        let etagKey = "\(etagPrefix).\(tab.rawValue).\(first).\(query)"
        if let storedEtag = settings.etag(for: etagKey) {
            request.setValue(storedEtag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.unknown(0)
        }

        try checkRateLimit(http)

        switch http.statusCode {
        case 304:
            throw GitHubAPIError.notModified
        case 401:
            throw GitHubAPIError.unauthorized
        case 200:
            break
        case 500...599:
            throw GitHubAPIError.serverError(http.statusCode)
        default:
            throw GitHubAPIError.unknown(http.statusCode)
        }

        if let newEtag = http.value(forHTTPHeaderField: "ETag") {
            settings.setEtag(newEtag, for: etagKey)
        }
        let newEtag = http.value(forHTTPHeaderField: "ETag")

        let decoded: GraphQLResponse
        do {
            decoded = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }

        // A bad/expired token can return 200 with a top-level errors array.
        if let errors = decoded.errors, !errors.isEmpty {
            if errors.contains(where: { ($0.type ?? "").uppercased().contains("FORBIDDEN") }) {
                throw GitHubAPIError.unauthorized
            }
            throw GitHubAPIError.unknown(200)
        }

        guard let nodes = decoded.data?.search.nodes else {
            return ([], newEtag)
        }

        // The authenticated user's login, used to resolve the viewer's own review
        // state (`viewerHasApproved`). Lowercased for case-insensitive matching.
        let myLogin = settings.githubUsername.lowercased()
        let snapshots: [PRSnapshot] = nodes.compactMap { node in
            Self.makeSnapshot(from: node, tab: tab, myLogin: myLogin)
        }

        return (snapshots, newEtag)
    }

    // MARK: - Search recently DONE PRs (merged/closed) — display-only

    /// Fetches recently completed PRs (merged OR closed-not-merged) for a tab.
    ///
    /// DISPLAY-ONLY: the caller must keep these OUT of `PRStateStore` /
    /// `PRDiffEngine` / notifications — a merged PR must never fire a "new PR"
    /// banner. The query is the tab's own author/reviewer qualifier plus
    /// `is:pr is:closed sort:updated-desc` (GitHub's `is:closed` includes merged +
    /// closed), bounded to `first: 30`. ETag is cached under a distinct per-tab key
    /// so it never collides with the open-fetch cache. Throws `.notModified` on 304
    /// so the caller can keep the prior Done set unchanged.
    func searchDonePRs(tab: ReviewTab, token: String) async throws -> (snapshots: [PRSnapshot], etag: String?) {
        let query = "\(Self.doneQualifier(for: tab)) is:pr is:closed sort:updated-desc"
        return try await runSearch(query: query, token: token, tab: tab, first: 30, etagPrefix: "graphql.done")
    }

    /// The user-scoped qualifier for a tab's Done query. Mirrors the open-fetch
    /// queries: `author:@me` for the Created tab, `review-requested:@me` for For me.
    private static func doneQualifier(for tab: ReviewTab) -> String {
        switch tab {
        case .created: return "author:@me"
        case .forMe:   return "review-requested:@me"
        case .inbox:   return "author:@me"   // Inbox derives from both; use author as a fallback
        }
    }

    // MARK: - Snapshot mapping

    private static func makeSnapshot(from node: GraphQLNode, tab: ReviewTab, myLogin: String) -> PRSnapshot? {
        // Non-PR results (issues) lack these fields — skip them.
        guard let nodeId = node.id,
              let number = node.number,
              let title = node.title,
              let url = node.url,
              let repo = node.repository?.nameWithOwner else {
            return nil
        }

        let merged = node.merged ?? false
        let closed = node.closed ?? false
        let stateRaw = (node.state ?? "OPEN").lowercased() == "open" ? "open" : "closed"

        let ciStatus = mapCIStatus(node.commits?.nodes.first?.commit.statusCheckRollup?.state)
        let decision = node.reviewDecision.flatMap { ReviewDecision(rawValue: $0) }
        let reviewCount = node.reviews?.totalCount ?? 0

        // Whether the latest comment / review was authored by a bot. When there
        // are no comments/reviews the flag is false (no bot activity to ignore).
        let lastCommentAuthor = node.comments?.nodes?.last?.author
        let lastReviewAuthor  = node.reviews?.nodes?.last?.author
        let lastCommentIsBot = PRSnapshot.isBot(typename: lastCommentAuthor?.typename,
                                                login: lastCommentAuthor?.login)
        let lastReviewIsBot  = PRSnapshot.isBot(typename: lastReviewAuthor?.typename,
                                                login: lastReviewAuthor?.login)

        // Derive a coarse reviewState for diff-engine continuity and open/in-review split.
        let reviewState: ReviewState
        switch decision {
        case .approved:         reviewState = .approved
        case .changesRequested: reviewState = .changesRequested
        default:                reviewState = reviewCount > 0 ? .changesRequested : .none
        }

        // Map GraphQL mergeable enum to Bool?
        let mergeableBool: Bool?
        switch node.mergeable?.uppercased() {
        case "MERGEABLE":   mergeableBool = true
        case "CONFLICTING": mergeableBool = false
        default:            mergeableBool = nil   // UNKNOWN or missing
        }

        // Extract requested reviewer logins (User reviewers)
        let requestedReviewers: [String] = node.reviewRequests?.nodes.compactMap {
            $0.requestedReviewer?.login
        } ?? []

        // Extract requested team slugs (Team reviewers), falling back to name.
        let requestedTeams: [String] = node.reviewRequests?.nodes.compactMap {
            let reviewer = $0.requestedReviewer
            guard reviewer?.login == nil else { return nil }   // skip User reviewers
            return reviewer?.slug ?? reviewer?.name
        } ?? []

        // Count unresolved review threads (open conversations). Sampled at first:20;
        // a PR with >20 threads still surfaces as needing attention on any unresolved.
        let unresolvedThreadCount: Int = node.reviewThreads?.nodes.filter {
            $0.isResolved == false
        }.count ?? 0

        // Determine whether the PR author is a bot.
        // `PRSnapshot.isBot` uses the same logic as comment/review author detection.
        let authorTypename = node.author?.typename
        let authorLogin    = node.author?.login ?? ""
        let authorIsBot    = PRSnapshot.isBot(typename: authorTypename, login: authorLogin)
            || InboxMuteEngine.isBotLogin(authorLogin)

        // Collect label names (first 10, decoded from GraphQL).
        let labels: [String] = node.labels?.nodes.compactMap { $0.name } ?? []

        // Whether the viewer's OWN latest review is an approval. `latestReviews`
        // returns the most recent review per author; match the viewer's login
        // (case-insensitive) and check for APPROVED. Empty myLogin → false.
        let viewerHasApproved: Bool = !myLogin.isEmpty && (node.latestReviews?.nodes.contains {
            ($0.author?.login?.lowercased() == myLogin)
                && ($0.state?.uppercased() == "APPROVED")
        } ?? false)

        return PRSnapshot(
            nodeId:             nodeId,
            number:             number,
            title:              title,
            htmlUrl:            url,
            repoFullName:       repo,
            isDraft:            node.isDraft ?? false,
            state:              stateRaw,
            merged:             merged,
            closed:             closed,
            reviewDecision:     decision,
            ciStatus:           ciStatus,
            reviewState:        reviewState,
            commentCount:       node.comments?.totalCount ?? 0,
            reviewCount:        reviewCount,
            lastCommentIsBot:   lastCommentIsBot,
            lastReviewIsBot:    lastReviewIsBot,
            updatedAt:          node.updatedAt ?? "",
            author:             authorLogin,
            requestedReviewers: requestedReviewers,
            requestedTeams:     requestedTeams,
            tabs:               [tab],
            mergeable:          mergeableBool,
            headRefName:        node.headRefName ?? "",
            linesAdded:         node.additions ?? 0,
            linesDeleted:       node.deletions ?? 0,
            unresolvedThreadCount: unresolvedThreadCount,
            mergeCommitAllowed: node.repository?.mergeCommitAllowed ?? true,
            squashMergeAllowed: node.repository?.squashMergeAllowed ?? true,
            rebaseMergeAllowed: node.repository?.rebaseMergeAllowed ?? true,
            labels:             labels,
            authorIsBot:        authorIsBot,
            viewerHasApproved:  viewerHasApproved
        )
    }

    /// Maps GraphQL `StatusState` to the app's CIStatus.
    private static func mapCIStatus(_ rollup: String?) -> CIStatus {
        guard let rollup else { return .unknown }
        switch rollup.uppercased() {
        case "SUCCESS":            return .success
        case "FAILURE":            return .failure
        case "ERROR":              return .error
        case "PENDING", "EXPECTED": return .pending
        default:                   return .unknown
        }
    }

    // MARK: - GraphQL document

    private static let searchQueryDocument = """
    query($q: String!, $first: Int!) {
      search(query: $q, type: ISSUE, first: $first) {
        nodes {
          ... on PullRequest {
            id
            number
            title
            url
            isDraft
            merged
            closed
            state
            reviewDecision
            updatedAt
            mergeable
            headRefName
            additions
            deletions
            author { __typename login }
            repository { nameWithOwner mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed }
            labels(first: 10) { nodes { name } }
            comments(last: 1) { totalCount nodes { author { __typename login } } }
            reviews(last: 1) { totalCount nodes { author { __typename login } } }
            reviewRequests(first: 10) {
              nodes {
                requestedReviewer {
                  ... on User { login }
                  ... on Team { slug name }
                }
              }
            }
            reviewThreads(first: 20) {
              nodes { isResolved }
            }
            latestReviews(first: 20) {
              nodes { state author { __typename login } }
            }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup { state }
                }
              }
            }
          }
        }
      }
    }
    """

    // MARK: - Fetch files (REST)

    /// Fetches the list of files changed in a PR.
    func fetchFiles(repoFullName: String, number: Int, token: String) async throws -> [PRFile] {
        let urlString = "https://api.github.com/repos/\(repoFullName)/pulls/\(number)/files?per_page=100"
        guard let url = URL(string: urlString) else { throw GitHubAPIError.unknown(0) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else { throw GitHubAPIError.unknown(0) }

        switch http.statusCode {
        case 200: break
        case 401: throw GitHubAPIError.unauthorized
        case 500...599: throw GitHubAPIError.serverError(http.statusCode)
        default:  throw GitHubAPIError.unknown(http.statusCode)
        }

        do {
            return try JSONDecoder().decode([PRFile].self, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }
    }

    // MARK: - Preview URL (REST)

    /// Fetches the PR's issue comments and extracts the preview URL from the ones
    /// posted by a configured author, then hands the joined bodies to
    /// `extractPreviewURL` for the tiered match. Returns nil when no preview is
    /// present.
    ///
    /// `authors` used to be hard-coded to `vercel[bot]`, which meant a repo that
    /// rolls its own preview deploy in GitHub Actions — posting as
    /// `github-actions[bot]` — had its comment skipped before the URL match ever
    /// ran. It is now the user's list; an EMPTY list means "scan every author".
    ///
    /// Uses the issue-comments endpoint (`/issues/{n}/comments`) because a PR's
    /// conversation comments are issue comments in the REST API — that's where
    /// deployment bots post their sticky comment.
    func fetchPreviewURL(
        repoFullName: String,
        number: Int,
        domains: [String],
        authors: [String],
        linkLabels: [String],
        token: String
    ) async throws -> String? {
        let urlString = "https://api.github.com/repos/\(repoFullName)/issues/\(number)/comments?per_page=100"
        guard let url = URL(string: urlString) else { throw GitHubAPIError.unknown(0) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else { throw GitHubAPIError.unknown(0) }

        switch http.statusCode {
        case 200: break
        case 401: throw GitHubAPIError.unauthorized
        case 500...599: throw GitHubAPIError.serverError(http.statusCode)
        default:  throw GitHubAPIError.unknown(http.statusCode)
        }

        let comments: [IssueComment]
        do {
            comments = try JSONDecoder().decode([IssueComment].self, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }

        let allowed = authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let botBody = comments
            .filter { comment in
                // Empty allow-list = scan every author (a bespoke GitHub App).
                guard !allowed.isEmpty else { return true }
                guard let login = comment.user?.login else { return false }
                return allowed.contains(login.lowercased())
            }
            .compactMap { $0.body }
            .joined(separator: "\n")

        return Self.extractPreviewURL(from: botBody, domains: domains, linkLabels: linkLabels)
    }

    /// Hosts that appear in a preview comment but are never the preview itself —
    /// Vercel's own comment links its dashboard (`vercel.com`) and its feedback
    /// widget (`vercel.live`) alongside the deployment, and a hand-rolled comment
    /// links back to the workflow run on `github.com`. Only the un-domained tier
    /// below consults this; a host the user explicitly listed always wins.
    static let nonPreviewHosts = ["github.com", "vercel.com", "vercel.live"]

    /// Pure preview-URL extractor, matched in three tiers so a custom preview
    /// comment works without Mainline knowing its layout. Within every tier the
    /// LAST match wins (the most recent deployment).
    ///
    /// 1. A markdown link whose label matches `linkLabels` AND whose host is on a
    ///    configured `domains` suffix — the strongest signal, and the one Vercel's
    ///    own `[Visit Preview](…)` cell hits.
    /// 2. A label-matched link on any other host (minus `nonPreviewHosts`). This is
    ///    what makes a bespoke preview domain work with no configuration at all.
    /// 3. A bare host-suffix scan over the whole body — the original behaviour,
    ///    kept so a comment that prints a naked URL still resolves.
    static func extractPreviewURL(
        from text: String,
        domains: [String],
        linkLabels: [String] = []
    ) -> String? {
        guard !text.isEmpty else { return nil }

        let cleanDomains = domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanLabels = linkLabels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var labelled: [MarkdownLink] = []
        if !cleanLabels.isEmpty {
            labelled = Self.markdownLinks(in: text).filter { link in
                let label = link.label.lowercased()
                return cleanLabels.contains { label.contains($0) }
            }
        }

        // Tier 1 — label AND domain, domains in priority order.
        for domain in cleanDomains {
            if let match = labelled.last(where: { Self.host($0.url, matchesSuffix: domain) }) {
                return match.url
            }
        }

        // Tier 2 — label alone, on a host that isn't a known non-preview one.
        if let match = labelled.last(where: { link in
            guard let h = URL(string: link.url)?.host?.lowercased() else { return false }
            return !Self.nonPreviewHosts.contains { h == $0 || h.hasSuffix("." + $0) }
        }) {
            return match.url
        }

        // Tier 3 — bare host-suffix scan (original behaviour).
        for domain in cleanDomains {
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            // https://<subdomain>.<suffix><optional path/query>, matching the
            // Alfred workflow's character classes.
            let pattern = "https://[a-zA-Z0-9._-]+\\.\(escaped)[a-zA-Z0-9./_?=&-]*"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            if let last = matches.last, let r = Range(last.range, in: text) {
                return String(text[r])
            }
        }
        return nil
    }

    /// A markdown inline link, `[label](url)`.
    struct MarkdownLink {
        let label: String
        let url: String
    }

    /// Extracts every `[label](http…)` inline link, in document order. Image links
    /// (`![alt](…)`) are skipped by requiring the character before `[` not to be
    /// `!` — otherwise the `![Ready](…status/ready.svg)` icon in a Vercel-shaped
    /// table would be read as a link whose "label" sits next to the real one.
    static func markdownLinks(in text: String) -> [MarkdownLink] {
        let pattern = "\\[([^\\[\\]]*)\\]\\((https?://[^\\s)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        var out: [MarkdownLink] = []
        for m in regex.matches(in: text, range: full) {
            guard let labelRange = Range(m.range(at: 1), in: text),
                  let urlRange   = Range(m.range(at: 2), in: text) else { continue }
            // Skip images: look at the character immediately before the `[`.
            if let whole = Range(m.range, in: text), whole.lowerBound > text.startIndex {
                let before = text[text.index(before: whole.lowerBound)]
                if before == "!" { continue }
            }
            out.append(MarkdownLink(label: String(text[labelRange]),
                                    url: String(text[urlRange])))
        }
        return out
    }

    /// Whether `urlString`'s host is `suffix` or a subdomain of it. Compared on the
    /// parsed host rather than the raw string so a path segment can never satisfy a
    /// domain match.
    static func host(_ urlString: String, matchesSuffix suffix: String) -> Bool {
        guard let h = URL(string: urlString)?.host?.lowercased() else { return false }
        let s = suffix.lowercased()
        return h == s || h.hasSuffix("." + s)
    }

    // MARK: - Perform GraphQL mutation

    /// Executes an arbitrary GraphQL mutation and decodes the response.
    func performMutation<T: Decodable>(
        _ gql: String,
        variables: [String: Any],
        token: String,
        responseType: T.Type
    ) async throws -> T {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            throw GitHubAPIError.unknown(0)
        }

        let bodyDict: [String: Any] = ["query": gql, "variables": variables]
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            throw GitHubAPIError.unknown(0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else { throw GitHubAPIError.unknown(0) }

        try checkRateLimit(http)

        switch http.statusCode {
        case 200: break
        case 401: throw GitHubAPIError.unauthorized
        case 500...599: throw GitHubAPIError.serverError(http.statusCode)
        default:  throw GitHubAPIError.unknown(http.statusCode)
        }

        // GitHub returns HTTP 200 with `data: null` + a top-level `errors` array
        // when a mutation is rejected (e.g. disallowed merge method, not mergeable,
        // already merged). Without this check a failed mutation is silently treated
        // as success. Surface it as a thrown, descriptive error.
        if let envelope = try? JSONDecoder().decode(GraphQLErrorEnvelope.self, from: data),
           let errors = envelope.errors, !errors.isEmpty {
            let message = errors.map { $0.message }.joined(separator: " ")
            throw GitHubAPIError.actionFailed(message)
        }

        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }
    }

    /// Minimal envelope for decoding a GraphQL response's top-level `errors` array,
    /// independent of the mutation's `data` shape.
    private struct GraphQLErrorEnvelope: Decodable {
        let errors: [GraphQLError]?
    }

    // MARK: - Mark Ready for Review mutation

    private static let markPullRequestReadyForReviewMutation = """
    mutation($pullRequestId: ID!) {
      markPullRequestReadyForReview(input: { pullRequestId: $pullRequestId }) {
        pullRequest { isDraft }
      }
    }
    """

    struct MarkReadyMutationResponse: Decodable {
        struct MarkReady: Decodable {
            struct PR: Decodable { let isDraft: Bool }
            let pullRequest: PR?
        }
        let data: MarkReady?
    }

    /// Marks a draft pull request as ready for review via GraphQL markPullRequestReadyForReview.
    func markReadyForReview(nodeId: String, token: String) async throws {
        let variables: [String: Any] = ["pullRequestId": nodeId]
        _ = try await performMutation(
            Self.markPullRequestReadyForReviewMutation,
            variables: variables,
            token: token,
            responseType: MarkReadyMutationResponse.self
        )
    }

    // MARK: - Review mutations

    private static let addPullRequestReviewMutation = """
    mutation($pullRequestId: ID!, $event: PullRequestReviewEvent!, $body: String) {
      addPullRequestReview(input: {
        pullRequestId: $pullRequestId,
        event: $event,
        body: $body
      }) {
        pullRequestReview { id }
      }
    }
    """

    private static let mergePullRequestMutation = """
    mutation($pullRequestId: ID!, $method: PullRequestMergeMethod!) {
      mergePullRequest(input: { pullRequestId: $pullRequestId, mergeMethod: $method }) {
        pullRequest { merged }
      }
    }
    """

    struct ReviewMutationResponse: Decodable {
        struct AddReview: Decodable {
            struct Review: Decodable { let id: String }
            let pullRequestReview: Review?
        }
        let data: AddReview?
    }

    struct MergeMutationResponse: Decodable {
        struct MergePR: Decodable {
            struct PR: Decodable { let merged: Bool }
            let pullRequest: PR?
        }
        let data: MergePR?
    }

    /// Approves a pull request via GraphQL addPullRequestReview.
    func approvePR(nodeId: String, token: String) async throws {
        let variables: [String: Any] = ["pullRequestId": nodeId, "event": "APPROVE"]
        _ = try await performMutation(
            Self.addPullRequestReviewMutation,
            variables: variables,
            token: token,
            responseType: ReviewMutationResponse.self
        )
    }

    /// Requests changes on a pull request.
    func requestChangesPR(nodeId: String, body: String, token: String) async throws {
        let variables: [String: Any] = ["pullRequestId": nodeId, "event": "REQUEST_CHANGES", "body": body]
        _ = try await performMutation(
            Self.addPullRequestReviewMutation,
            variables: variables,
            token: token,
            responseType: ReviewMutationResponse.self
        )
    }

    /// Merges a pull request using the method resolved from the PR's repo
    /// capabilities and the user's preference. GitHub rejects a disallowed merge
    /// method (e.g. MERGE when `allow_merge_commit=false`) with a top-level
    /// `errors` array, which `performMutation` now surfaces as `.actionFailed`.
    func mergePR(pr: PRSnapshot, preference: MergeMethodPreference, token: String) async throws {
        let method = Self.resolveMergeMethod(for: pr, preference: preference)
        let variables: [String: Any] = ["pullRequestId": pr.nodeId, "method": method.graphQLValue]
        _ = try await performMutation(
            Self.mergePullRequestMutation,
            variables: variables,
            token: token,
            responseType: MergeMutationResponse.self
        )
    }

    /// Resolves the GraphQL `PullRequestMergeMethod` to send, given the PR's repo
    /// capabilities and the user's preference. Never returns a method the repo
    /// disallows: an explicit choice that isn't allowed falls back to the auto
    /// order (squash → rebase → merge). If the repo allows none (shouldn't happen),
    /// defaults to `.squash` so we send *something* and let GitHub report the error.
    static func resolveMergeMethod(for pr: PRSnapshot, preference: MergeMethodPreference) -> GitHubMergeMethod {
        let autoResolved: GitHubMergeMethod = {
            if pr.squashMergeAllowed { return .squash }
            if pr.rebaseMergeAllowed { return .rebase }
            if pr.mergeCommitAllowed { return .merge }
            return .squash
        }()

        switch preference {
        case .auto:
            return autoResolved
        case .squash:
            return pr.squashMergeAllowed ? .squash : autoResolved
        case .rebase:
            return pr.rebaseMergeAllowed ? .rebase : autoResolved
        case .merge:
            return pr.mergeCommitAllowed ? .merge : autoResolved
        }
    }

    // MARK: - Helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch is CancellationError {
            // SwiftUI cancelled the in-flight `.task` (e.g. popover closed). Benign.
            throw GitHubAPIError.cancelled
        } catch let error as URLError {
            // URLError.cancelled fires routinely when the popover closes mid-request.
            if error.code == .cancelled {
                throw GitHubAPIError.cancelled
            }
            throw GitHubAPIError.networkError(error)
        }
    }

    private func checkRateLimit(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 {
            let retryAfter = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            throw GitHubAPIError.rateLimited(retryAfter: retryAfter)
        }
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           remaining == "0",
           let resetTimestamp = Int(reset) {
            let now = Int(Date().timeIntervalSince1970)
            let wait = max(resetTimestamp - now, 1)
            throw GitHubAPIError.rateLimited(retryAfter: wait)
        }
    }
}

#if DEBUG
/// Asserts the preview-URL extractor against the real comment shapes it has to
/// survive. Invoked once at app launch in DEBUG builds from
/// MainlineApp/AppDelegate, alongside `InboxMuteEngine.runSelfChecks()`.
///
/// Compiling these is not the same as running them — they execute only when
/// someone launches a Debug build. They also cover the pure extractor ONLY: the
/// author allow-list lives in `fetchPreviewURL`'s network path and is not
/// exercised here.
enum PreviewDetectionChecks {
    static func run() {
        let domains = MainlineSettings.defaultVercelPreviewDomains
        let labels  = MainlineSettings.defaultPreviewLinkLabels

        // --- Vercel's own sticky comment (the shape that already worked) ---
        let vercel = """
        | Name | Status | Preview | Comments | Updated (UTC) |
        | :--- | :----- | :------ | :------- | :------ |
        | **web** | ✅ Ready ([Inspect](https://vercel.com/acme/web/9xk)) | \
        [Visit Preview](https://web-git-feat-acme.vercel.app) | \
        💬 [**Add feedback**](https://vercel.live/open-feedback/web.vercel.app) | Sep 1, 2026 |
        """
        assert(extract(vercel, domains, labels) == "https://web-git-feat-acme.vercel.app",
               "preview: Vercel's [Visit Preview] cell must win over [Inspect]/[Add feedback]")

        // --- A hand-rolled GitHub Actions comment: Vercel-shaped table ---
        // The `[Ready](…)` cell is the IMMUTABLE per-commit build and appears
        // BEFORE `[Preview](…)`; only the labelled one may be returned.
        let custom = """
        <!-- lorekit-web-preview sha=0123456789abcdef0123456789abcdef01234567 -->
        The dashboard preview for this PR.

        | Project | Deployment | Actions | Updated |
        | :--- | :----- | :------ | :------ |
        | **lorekit** | ![Ready](https://vercel.com/static/status/ready.svg) \
        [Ready](https://lorekit-abc123.vercel.app) | \
        [Preview](https://lorekit-pr-650.vercel.app) | Sep 1, 2026 |
        """
        assert(extract(custom, domains, labels) == "https://lorekit-pr-650.vercel.app",
               "preview: the [Preview] link must win over the [Ready] per-commit build")

        // --- A hand-rolled comment with the URL inside the link label ---
        let inline = "🔗 **[Open preview → https://lorekit-x.vercel.app](https://lorekit-x.vercel.app)**"
        assert(extract(inline, domains, labels) == "https://lorekit-x.vercel.app",
               "preview: [Open preview → url](url) must resolve")

        // --- The failure comment must yield nothing ---
        let failed = """
        <!-- lorekit-web-preview -->
        | Project | Deployment | Actions | Updated |
        | **lorekit** | ![Error](https://vercel.com/static/status/error.svg) Error | — | Sep 1, 2026 |
        > **The preview deploy for `abc1234` failed — no preview is available.**
        [Workflow logs](https://github.com/mthines/lorekit/actions/runs/42)
        """
        assert(extract(failed, domains, labels) == nil,
               "preview: a failed deploy has no preview URL — the status icon and the workflow link are not one")

        // --- Tier 2: a labelled link on a domain the user never listed ---
        let bespoke = "Deployed. [Preview](https://pr-650.previews.acme.internal/dash)"
        assert(extract(bespoke, domains, labels) == "https://pr-650.previews.acme.internal/dash",
               "preview: a labelled link must resolve on an unlisted host (tier 2)")

        // --- Tier 3: a bare URL with no markdown link at all ---
        let bare = "Preview is up: https://web-git-feat.vercel.app"
        assert(extract(bare, domains, labels) == "https://web-git-feat.vercel.app",
               "preview: a naked URL on a configured domain must still resolve (tier 3)")

        // --- An image's alt text is not a link label ---
        let image = "![preview](https://img.example.com/badge.svg) build failed"
        assert(extract(image, domains, labels) == nil,
               "preview: ![preview](…) is an image, not a preview link")

        // --- Domain priority is honoured within tier 1 ---
        let both = "[Preview](https://a.vercel.app) and [Preview](https://b.dash0-preview.com)"
        assert(extract(both, domains, labels) == "https://b.dash0-preview.com",
               "preview: dash0-preview.com outranks vercel.app")

        // --- A host suffix must match on the host, not on the path ---
        let pathTrap = "[Preview](https://github.com/acme/web/tree/vercel.app)"
        assert(extract(pathTrap, domains, labels) == nil,
               "preview: 'vercel.app' in a github.com path is not a preview host")

        // --- Clearing the labels degrades to the original domain-only behaviour ---
        assert(extract(custom, domains, []) == "https://lorekit-pr-650.vercel.app",
               "preview: with no labels, tier 3 takes the LAST matching URL")
        assert(extract(bespoke, domains, []) == nil,
               "preview: with no labels, an unlisted host cannot be found")
    }

    private static func extract(_ text: String, _ domains: [String], _ labels: [String]) -> String? {
        GitHubClient.extractPreviewURL(from: text, domains: domains, linkLabels: labels)
    }
}
#endif
