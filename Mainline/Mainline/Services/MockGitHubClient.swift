import Foundation

// MARK: - GitHubAPI

/// The network surface the rest of the app depends on. Extracted so that
/// production (`GitHubClient`) and demo/recording mode (`MockGitHubClient`) are
/// interchangeable: `PRManager`, `PRPoller`, and `PRPeekView` all hold a
/// `GitHubAPI` and never care which one is behind it.
///
/// Only the methods actually exercised by polling, peeking, and the write actions
/// are listed here. Static helpers (`GitHubClient.resolveMergeMethod`,
/// `vercelBotLogin`) stay on the concrete type.
protocol GitHubAPI: AnyObject {
    func searchPRs(query: String, token: String, tab: ReviewTab) async throws -> (snapshots: [PRSnapshot], etag: String?)
    func searchDonePRs(tab: ReviewTab, token: String) async throws -> (snapshots: [PRSnapshot], etag: String?)
    func fetchFiles(repoFullName: String, number: Int, token: String) async throws -> [PRFile]
    func fetchVercelPreviewURL(repoFullName: String, number: Int, domains: [String], token: String) async throws -> String?
    func approvePR(nodeId: String, token: String) async throws
    func requestChangesPR(nodeId: String, body: String, token: String) async throws
    func mergePR(pr: PRSnapshot, preference: MergeMethodPreference, token: String) async throws
}

/// The real client already implements every requirement; this just advertises the
/// conformance so it can stand in for `GitHubAPI`.
extension GitHubClient: GitHubAPI {}

// MARK: - MockGitHubClient

/// In-memory fake used by demo / screen-recording mode (`DemoMode`). Serves a
/// canned dataset and mutates it in response to the write actions, so the app's
/// real machinery (poll loop, diff engine, store, notifications, keyboard triage)
/// runs unchanged and a recording shows genuine behaviour:
///
/// - **Approve** flips a PR to `APPROVED` (green + mergeable PRs then surface under
///   "Ready to merge").
/// - **Request changes** flips a PR to `CHANGES_REQUESTED` (moves it into "Needs
///   attention").
/// - **Merge** removes the PR from the open set and drops it into the Done set, so
///   the next poll animates it out of the deck and into "Done".
///
/// An `actor` so its mutable state is safe without locks; all requirements are
/// `async`, which actor-isolated methods satisfy directly. No token is used and no
/// network call is ever made.
actor MockGitHubClient: GitHubAPI {
    private var open: [PRSnapshot]
    private var done: [PRSnapshot]

    init(myLogin: String) {
        let data = DemoMode.dataset(myLogin: myLogin)
        self.open = data.open
        self.done = data.done
    }

    // MARK: - Reads

    func searchPRs(query: String, token: String, tab: ReviewTab) async throws -> (snapshots: [PRSnapshot], etag: String?) {
        // The poller queries once per tab (.created / .forMe). Return each PR whose
        // tab membership includes the requested tab. Nil etag → the poller always
        // re-diffs (a no-op when nothing changed, so the steady state stays quiet).
        (open.filter { $0.tabs.contains(tab) }, nil)
    }

    func searchDonePRs(tab: ReviewTab, token: String) async throws -> (snapshots: [PRSnapshot], etag: String?) {
        (done.filter { $0.tabs.contains(tab) }, nil)
    }

    func fetchVercelPreviewURL(repoFullName: String, number: Int, domains: [String], token: String) async throws -> String? {
        // Previews are pre-populated on the snapshots themselves (see
        // DemoMode.withPreview), so the enrichment pass never reaches here for the
        // seeded set. Kept faithful for any PR that asks: derive a stable URL.
        open.first { $0.repoFullName == repoFullName && $0.number == number }?.vercelPreviewUrl
    }

    func fetchFiles(repoFullName: String, number: Int, token: String) async throws -> [PRFile] {
        Self.demoFiles(repoFullName: repoFullName, number: number)
    }

    // MARK: - Writes (mutate the in-memory state so the next poll reflects them)

    func approvePR(nodeId: String, token: String) async throws {
        mutate(nodeId) {
            $0.reviewDecision = .approved
            $0.reviewState = .approved
            $0.unresolvedThreadCount = 0
            $0.reviewCount += 1
        }
    }

    func requestChangesPR(nodeId: String, body: String, token: String) async throws {
        mutate(nodeId) {
            $0.reviewDecision = .changesRequested
            $0.reviewState = .changesRequested
            $0.reviewCount += 1
            if $0.unresolvedThreadCount == 0 { $0.unresolvedThreadCount = 1 }
        }
    }

    func mergePR(pr: PRSnapshot, preference: MergeMethodPreference, token: String) async throws {
        guard let idx = open.firstIndex(where: { $0.nodeId == pr.nodeId }) else { return }
        var merged = open.remove(at: idx)
        merged.merged = true
        merged.closed = true
        merged.state = "closed"
        merged.updatedAt = Self.now()
        done.insert(merged, at: 0)
    }

    // MARK: - Helpers

    /// Applies `change` to the open PR with `nodeId` and freshens its `updatedAt`
    /// so the diff engine registers the transition on the next poll.
    private func mutate(_ nodeId: String, _ change: (inout PRSnapshot) -> Void) {
        guard let idx = open.firstIndex(where: { $0.nodeId == nodeId }) else { return }
        var snap = open[idx]
        change(&snap)
        snap.updatedAt = Self.now()
        open[idx] = snap
    }

    private static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// A small, deterministic file list per PR so the peek card's file section
    /// looks realistic. Varies count/paths by PR number.
    private static func demoFiles(repoFullName: String, number: Int) -> [PRFile] {
        let pool: [(String, Int, Int, String)] = [
            ("src/App.swift", 42, 8, "modified"),
            ("src/Views/OverviewPanel.swift", 96, 4, "modified"),
            ("src/Services/MetricsClient.swift", 30, 12, "modified"),
            ("src/Models/Panel.swift", 18, 2, "modified"),
            ("tests/OverviewPanelTests.swift", 64, 0, "added"),
            ("README.md", 6, 1, "modified"),
            ("src/legacy/OldChart.swift", 0, 120, "removed"),
        ]
        let count = 3 + (number % 4)          // 3…6 files, stable per PR
        let start = number % max(1, pool.count - count)
        return Array(pool[start..<min(start + count, pool.count)]).map {
            PRFile(filename: $0.0, additions: $0.1, deletions: $0.2, status: $0.3)
        }
    }
}
