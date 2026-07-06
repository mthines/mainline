import Foundation

// MARK: - Error Types

enum GitHubAPIError: Error, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: Int)   // seconds
    case notModified                    // 304 — no changes
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
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .decodingError(let err):
            return "Failed to decode GitHub response: \(err.localizedDescription)"
        case .unknown(let code):
            return "Unexpected HTTP status: \(code)"
        }
    }
}

// MARK: - GitHub API Response Models (private to this file)

private struct SearchResponse: Decodable {
    let items: [IssueItem]
}

private struct IssueItem: Decodable {
    let node_id: String
    let number: Int
    let title: String
    let html_url: String
    let draft: Bool?
    let state: String
    let user: GitHubUser
    let comments: Int
    let updated_at: String
    let requested_reviewers: [GitHubUser]
    let pull_request: PullRequestLinks?
    let repository_url: String   // "https://api.github.com/repos/owner/repo"
}

private struct GitHubUser: Decodable {
    let login: String
}

private struct PullRequestLinks: Decodable {
    let url: String
}

private struct CheckRunsResponse: Decodable {
    let check_runs: [CheckRun]
}

private struct CheckRun: Decodable {
    let status: String       // "queued" | "in_progress" | "completed"
    let conclusion: String?  // "success" | "failure" | "neutral" | "cancelled" | "timed_out" | "action_required"
}

// MARK: - GitHubClient

final class GitHubClient {
    private let session: URLSession
    private let settings: PerchSettings

    init(settings: PerchSettings = .shared) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Search PRs

    /// Search for PRs matching `query`.
    /// Returns the snapshot array and the new ETag (if any).
    /// Throws `.notModified` if the server returned 304.
    func searchPRs(query: String, token: String) async throws -> (snapshots: [PRSnapshot], etag: String?) {
        let urlString = "https://api.github.com/search/issues?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&per_page=100"
        guard let url = URL(string: urlString) else {
            throw GitHubAPIError.unknown(0)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        // If-None-Match caching
        if let storedEtag = settings.etag(for: urlString) {
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
        default:
            throw GitHubAPIError.unknown(http.statusCode)
        }

        let newEtag = http.value(forHTTPHeaderField: "ETag")
        if let newEtag {
            settings.setEtag(newEtag, for: urlString)
        }

        let searchResponse: SearchResponse
        do {
            searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }

        // Filter to PRs only (search/issues returns both issues and PRs)
        let prItems = searchResponse.items.filter { $0.pull_request != nil }

        // Fetch CI status for each PR
        var snapshots: [PRSnapshot] = []
        for item in prItems {
            let repoFullName = extractRepoFullName(from: item.repository_url)
            let ciStatus = await fetchCIStatus(
                repoFullName: repoFullName,
                prNumber: item.number,
                token: token
            )
            let snapshot = PRSnapshot(
                nodeId:             item.node_id,
                number:             item.number,
                title:              item.title,
                htmlUrl:            item.html_url,
                repoFullName:       repoFullName,
                isDraft:            item.draft ?? false,
                state:              item.state,
                ciStatus:           ciStatus,
                reviewState:        .none,
                commentCount:       item.comments,
                updatedAt:          item.updated_at,
                author:             item.user.login,
                requestedReviewers: item.requested_reviewers.map { $0.login }
            )
            snapshots.append(snapshot)
        }

        return (snapshots, newEtag)
    }

    // MARK: - CI Status

    /// Fetches the aggregated CI status from check-runs for a given PR.
    private func fetchCIStatus(repoFullName: String, prNumber: Int, token: String) async -> CIStatus {
        let urlString = "https://api.github.com/repos/\(repoFullName)/commits/\(prNumber)/check-runs"
        guard let url = URL(string: urlString) else { return .unknown }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if let etag = settings.etag(for: urlString) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        guard let (data, response) = try? await performRequest(request),
              let http = response as? HTTPURLResponse else {
            return .unknown
        }

        if http.statusCode == 304 {
            return .unknown // no change — caller will use previous value
        }

        if let etag = http.value(forHTTPHeaderField: "ETag") {
            settings.setEtag(etag, for: urlString)
        }

        guard http.statusCode == 200,
              let cr = try? JSONDecoder().decode(CheckRunsResponse.self, from: data) else {
            return .unknown
        }

        return aggregateCIStatus(from: cr.check_runs)
    }

    private func aggregateCIStatus(from runs: [CheckRun]) -> CIStatus {
        if runs.isEmpty { return .unknown }
        if runs.contains(where: { $0.status == "in_progress" || $0.status == "queued" }) {
            return .pending
        }
        if runs.contains(where: { $0.conclusion == "failure" || $0.conclusion == "timed_out" || $0.conclusion == "action_required" }) {
            return .failure
        }
        if runs.contains(where: { $0.conclusion == "cancelled" }) {
            return .error
        }
        if runs.allSatisfy({ $0.conclusion == "success" || $0.conclusion == "neutral" || $0.conclusion == "skipped" }) {
            return .success
        }
        return .unknown
    }

    // MARK: - Helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
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

    private func extractRepoFullName(from repositoryUrl: String) -> String {
        // "https://api.github.com/repos/owner/repo" -> "owner/repo"
        let prefix = "https://api.github.com/repos/"
        if repositoryUrl.hasPrefix(prefix) {
            return String(repositoryUrl.dropFirst(prefix.count))
        }
        return repositoryUrl
    }
}
