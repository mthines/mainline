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

    var errorDescription: String? {
        switch self {
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
    let comments: GraphQLCount?
    let reviews: GraphQLCount?
    let commits: GraphQLCommits?
    // Triage Cockpit additions
    let mergeable: String?       // MERGEABLE | CONFLICTING | UNKNOWN
    let headRefName: String?
    let additions: Int?
    let deletions: Int?
    let reviewRequests: GraphQLReviewRequests?
    let reviewThreads: GraphQLReviewThreads?
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

/// Response model for REST `/repos/{owner}/{repo}/pulls/{number}/files`.
struct PRFile: Decodable {
    let filename: String
    let additions: Int
    let deletions: Int
}

private struct GraphQLActor: Decodable {
    let login: String?
}

private struct GraphQLRepository: Decodable {
    let nameWithOwner: String
}

private struct GraphQLCount: Decodable {
    let totalCount: Int
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

    /// Search for PRs matching `query` and tag the results with `tab`.
    /// GraphQL returns review decision + CI rollup in a single round trip, so
    /// no per-PR check-runs fan-out is needed.
    /// Throws `.notModified` if the server returned 304 (ETag unchanged).
    func searchPRs(query: String, token: String, tab: ReviewTab) async throws -> (snapshots: [PRSnapshot], etag: String?) {
        try await runSearch(query: query, token: token, tab: tab, first: 100, etagPrefix: "graphql.search")
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

        // ETag caching — keyed per prefix + tab + query so the two tabs (and the
        // open vs. done fetches) never collide.
        let etagKey = "\(etagPrefix).\(tab.rawValue).\(query)"
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

        let snapshots: [PRSnapshot] = nodes.compactMap { node in
            Self.makeSnapshot(from: node, tab: tab)
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
        }
    }

    // MARK: - Snapshot mapping

    private static func makeSnapshot(from node: GraphQLNode, tab: ReviewTab) -> PRSnapshot? {
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
            updatedAt:          node.updatedAt ?? "",
            author:             node.author?.login ?? "",
            requestedReviewers: requestedReviewers,
            requestedTeams:     requestedTeams,
            tabs:               [tab],
            mergeable:          mergeableBool,
            headRefName:        node.headRefName ?? "",
            linesAdded:         node.additions ?? 0,
            linesDeleted:       node.deletions ?? 0,
            unresolvedThreadCount: unresolvedThreadCount
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
            author { login }
            repository { nameWithOwner }
            comments { totalCount }
            reviews { totalCount }
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

    // MARK: - Fetch diff (REST)

    /// Fetches the unified diff text for a PR.
    /// Caps the response at 512 KB to avoid OOM on very large PRs.
    func fetchDiff(repoFullName: String, number: Int, token: String) async throws -> String {
        let urlString = "https://api.github.com/repos/\(repoFullName)/pulls/\(number)"
        guard let url = URL(string: urlString) else { throw GitHubAPIError.unknown(0) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.v3.diff", forHTTPHeaderField: "Accept")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else { throw GitHubAPIError.unknown(0) }

        switch http.statusCode {
        case 200: break
        case 401: throw GitHubAPIError.unauthorized
        case 500...599: throw GitHubAPIError.serverError(http.statusCode)
        default:  throw GitHubAPIError.unknown(http.statusCode)
        }

        let cap = 512 * 1024  // 512 KB
        let truncated = data.count > cap ? data.prefix(cap) : data
        return String(data: truncated, encoding: .utf8) ?? String(data: truncated, encoding: .isoLatin1) ?? ""
    }

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

        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }
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
    mutation($pullRequestId: ID!) {
      mergePullRequest(input: { pullRequestId: $pullRequestId }) {
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

    /// Merges a pull request.
    func mergePR(nodeId: String, token: String) async throws {
        let variables: [String: Any] = ["pullRequestId": nodeId]
        _ = try await performMutation(
            Self.mergePullRequestMutation,
            variables: variables,
            token: token,
            responseType: MergeMutationResponse.self
        )
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
