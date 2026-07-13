import Foundation

/// # Demo / Screen-recording mode
///
/// A **temporary, opt-in** switch that swaps the live GitHub network layer for a
/// canned in-memory dataset (`MockGitHubClient`). Everything else in the app runs
/// exactly as in production — polling, the diff engine, the store, notifications,
/// keyboard triage, collapsing/hiding, snooze, mute, and the write actions
/// (Approve / Merge / Request changes). Only the endpoint is faked, so a recording
/// shows real behaviour against a rich, deterministic set of PRs that covers every
/// visual state.
///
/// ## Enabling it
///
/// Either mechanism turns demo mode on (checked live, no rebuild needed for the
/// UserDefaults route):
///
/// 1. **Environment variable** — best when launching from Xcode or a terminal:
///    ```
///    MAINLINE_DEMO=1 /Applications/Mainline.app/Contents/MacOS/Mainline
///    ```
///    (In Xcode: Product → Scheme → Edit Scheme → Run → Arguments → add
///    `MAINLINE_DEMO = 1` under Environment Variables.)
///
/// 2. **UserDefaults flag** — best for a distributed `.app`; toggle without a
///    rebuild:
///    ```
///    defaults write com.mainline.github-pr-notifier demoModeEnabled -bool YES
///    # …record…
///    defaults delete com.mainline.github-pr-notifier demoModeEnabled
///    ```
///
/// Demo mode does not require a GitHub token and never touches the network. Its
/// PR-snapshot cache is written to a **separate** file (see `PRStateStore`), so it
/// never pollutes — or is polluted by — your real polling history.
enum DemoMode {

    /// UserDefaults key mirrored in `MainlineSettings` docs. Kept as a literal here
    /// so the flag can be read without constructing `MainlineSettings`.
    static let defaultsKey = "demoModeEnabled"

    /// Environment-variable name checked at launch.
    static let envKey = "MAINLINE_DEMO"

    /// Fallback login used for "your" PRs when no real username is configured.
    static let demoLogin = "mthines"

    /// Whether demo mode is active. True when the env var is a truthy value OR the
    /// UserDefaults flag is set. Cheap; safe to call from any thread.
    static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment[envKey]?.lowercased(),
           ["1", "true", "yes", "on"].contains(raw) {
            return true
        }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// The login to treat as "me" in demo mode. Prefers the real configured
    /// username (so the Inbox role split and attention logic line up with whatever
    /// is on-screen); falls back to `demoLogin` when none is set.
    static func login(for settings: MainlineSettings) -> String {
        settings.githubUsername.isEmpty ? demoLogin : settings.githubUsername
    }

    // MARK: - Dataset

    /// Builds the full demo dataset — a rich spread engineered to exercise every
    /// section and badge the app can show, split into the open set (diff-engine
    /// backed) and the display-only Done set.
    ///
    /// Coverage:
    /// - **Ready to merge** (approved + mergeable + green CI)
    /// - **Needs attention** via each driver: failing CI, changes requested,
    ///   unresolved review threads
    /// - **Waiting** (awaiting review, green)
    /// - **Draft** (with pending CI)
    /// - **Team** vs **Direct** review requests (For me tab)
    /// - **Muted / low-priority** bot PRs (Dependabot `chore(deps)` / `build(deps)`)
    /// - **Vercel preview** badges (pre-populated so they show instantly)
    /// - A **large** migration PR (big +/- line counts)
    /// - **Done**: merged and closed-not-merged, across both tabs
    /// - Multiple orgs/repos so the scope chips populate (`dash0hq`, `mthines`)
    static func dataset(myLogin: String) -> (open: [PRSnapshot], done: [PRSnapshot]) {
        let iso = ISO8601DateFormatter()
        func ago(_ minutes: Int) -> String {
            iso.string(from: Date().addingTimeInterval(TimeInterval(-minutes * 60)))
        }

        // Small builder to keep the dataset readable. Unspecified fields fall back
        // to PRSnapshot's own defaults.
        func pr(
            _ id: String,
            _ repo: String,
            _ number: Int,
            _ title: String,
            author: String,
            tabs: Set<ReviewTab>,
            isDraft: Bool = false,
            merged: Bool = false,
            closed: Bool = false,
            decision: ReviewDecision? = nil,
            ci: CIStatus = .unknown,
            reviewCount: Int = 0,
            requestedReviewers: [String] = [],
            requestedTeams: [String] = [],
            mergeable: Bool? = true,
            head: String,
            adds: Int = 0,
            dels: Int = 0,
            unresolved: Int = 0,
            labels: [String] = [],
            authorIsBot: Bool = false,
            preview: String? = nil,
            updated: String
        ) -> PRSnapshot {
            let state = (merged || closed) ? "closed" : "open"
            let reviewState: ReviewState = {
                switch decision {
                case .approved:         return .approved
                case .changesRequested: return .changesRequested
                default:                return reviewCount > 0 ? .changesRequested : .none
                }
            }()
            return PRSnapshot(
                nodeId: id,
                number: number,
                title: title,
                htmlUrl: "https://github.com/\(repo)/pull/\(number)",
                repoFullName: repo,
                isDraft: isDraft,
                state: state,
                merged: merged,
                closed: closed,
                reviewDecision: decision,
                ciStatus: ci,
                reviewState: reviewState,
                commentCount: unresolved + reviewCount,
                reviewCount: reviewCount,
                lastCommentIsBot: authorIsBot,
                lastReviewIsBot: false,
                updatedAt: updated,
                author: author,
                requestedReviewers: requestedReviewers,
                requestedTeams: requestedTeams,
                tabs: tabs,
                mergeable: mergeable,
                headRefName: head,
                linesAdded: adds,
                linesDeleted: dels,
                unresolvedThreadCount: unresolved,
                labels: labels,
                authorIsBot: authorIsBot
            ).withPreview(preview)
        }

        // MARK: Created (authored by me)
        let created: [PRSnapshot] = [
            pr("demo-c1", "dash0hq/dashboards", 482,
               "Add p99 latency panel to service overview",
               author: myLogin, tabs: [.created],
               decision: .approved, ci: .success, reviewCount: 2,
               mergeable: true, head: "feat/p99-latency-panel",
               adds: 184, dels: 22, labels: ["dashboards"],
               preview: "https://dashboards-pr-482.dash0-preview.com",
               updated: ago(6)),

            pr("demo-c2", "dash0hq/dash0", 1203,
               "Refactor ingestion pipeline batching",
               author: myLogin, tabs: [.created],
               decision: .reviewRequired, ci: .failure, reviewCount: 1,
               mergeable: true, head: "refactor/ingest-batching",
               adds: 642, dels: 210, labels: ["backend"],
               updated: ago(18)),

            pr("demo-c3", "dash0hq/website", 92,
               "Redesign pricing page",
               author: myLogin, tabs: [.created],
               decision: .changesRequested, ci: .success, reviewCount: 3,
               mergeable: true, head: "design/pricing-redesign",
               adds: 410, dels: 96, unresolved: 2, labels: ["design"],
               preview: "https://website-pr-92.dash0-preview.com",
               updated: ago(41)),

            pr("demo-c4", "dash0hq/otel-collector", 57,
               "Increase receiver buffer size default",
               author: myLogin, tabs: [.created],
               decision: nil, ci: .success,
               mergeable: true, head: "fix/receiver-buffer",
               adds: 12, dels: 4,
               updated: ago(73)),

            pr("demo-c5", "mthines/mainline", 14,
               "WIP: inline diff in the peek view",
               author: myLogin, tabs: [.created],
               isDraft: true, decision: nil, ci: .pending,
               mergeable: nil, head: "feat/peek-inline-diff",
               adds: 221, dels: 9,
               updated: ago(120)),

            pr("demo-c6", "dash0hq/dash0", 1188,
               "Tighten auth token scopes",
               author: myLogin, tabs: [.created],
               decision: nil, ci: .success, reviewCount: 1,
               mergeable: true, head: "security/token-scopes",
               adds: 75, dels: 30, unresolved: 3, labels: ["security"],
               updated: ago(200)),
        ]

        // MARK: For me (review requested of me / my team)
        let forMe: [PRSnapshot] = [
            pr("demo-r1", "dash0hq/dashboards", 501,
               "Fix legend overflow on mobile widths",
               author: "petra", tabs: [.forMe],
               decision: nil, ci: .success,
               requestedReviewers: [myLogin],
               mergeable: true, head: "fix/legend-overflow",
               adds: 40, dels: 12,
               updated: ago(9)),

            pr("demo-r2", "dash0hq/dash0", 1210,
               "Add retry + backoff to OTLP exporter",
               author: "jonas", tabs: [.forMe],
               decision: nil, ci: .failure, reviewCount: 1,
               requestedReviewers: [myLogin],
               mergeable: true, head: "feat/otlp-retry",
               adds: 130, dels: 18, unresolved: 1, labels: ["backend"],
               updated: ago(27)),

            pr("demo-r3", "dash0hq/otel-collector", 60,
               "Support gzip request compression",
               author: "lena", tabs: [.forMe],
               decision: nil, ci: .success,
               requestedReviewers: [], requestedTeams: ["backend"],
               mergeable: true, head: "feat/gzip-compression",
               adds: 88, dels: 22,
               updated: ago(55)),

            pr("demo-r4", "dash0hq/website", 101,
               "Add customer logos section to home page",
               author: "sofia", tabs: [.forMe],
               decision: nil, ci: .success,
               requestedReviewers: [myLogin],
               mergeable: true, head: "feat/customer-logos",
               adds: 60, dels: 0, labels: ["design"],
               preview: "https://website-pr-101.dash0-preview.com",
               updated: ago(88)),

            pr("demo-r5", "dash0hq/dash0", 1215,
               "chore(deps): bump golang.org/x/net from 0.17.0 to 0.19.0",
               author: "dependabot[bot]", tabs: [.forMe],
               decision: nil, ci: .success,
               requestedReviewers: [myLogin],
               mergeable: true, head: "dependabot/go_modules/golang.org/x/net-0.19.0",
               adds: 2, dels: 2, labels: ["dependencies"],
               authorIsBot: true,
               updated: ago(140)),

            pr("demo-r6", "dash0hq/dashboards", 505,
               "build(deps): bump vite from 5.0.0 to 5.2.0",
               author: "dependabot[bot]", tabs: [.forMe],
               decision: nil, ci: .success,
               requestedReviewers: [myLogin],
               mergeable: true, head: "dependabot/npm_and_yarn/vite-5.2.0",
               adds: 6, dels: 6, labels: ["dependencies"],
               authorIsBot: true,
               updated: ago(165)),

            pr("demo-r7", "dash0hq/dash0", 1200,
               "Migrate telemetry to OpenTelemetry SDK 1.30",
               author: "marcus", tabs: [.forMe],
               decision: nil, ci: .success, reviewCount: 1,
               requestedReviewers: [myLogin],
               mergeable: false, head: "chore/otel-sdk-1.30",
               adds: 2410, dels: 1812, labels: ["large", "backend"],
               updated: ago(230)),
        ]

        // MARK: Done (display-only: merged / closed)
        let done: [PRSnapshot] = [
            pr("demo-d1", "dash0hq/dashboards", 470,
               "Add dark mode toggle",
               author: myLogin, tabs: [.created],
               merged: true, decision: .approved, ci: .success, reviewCount: 2,
               mergeable: true, head: "feat/dark-mode",
               adds: 320, dels: 45,
               updated: ago(600)),

            pr("demo-d2", "dash0hq/dash0", 1150,
               "Cache dashboard query results",
               author: myLogin, tabs: [.created],
               merged: true, decision: .approved, ci: .success, reviewCount: 3,
               mergeable: true, head: "perf/query-cache",
               adds: 210, dels: 60,
               updated: ago(900)),

            pr("demo-d3", "dash0hq/website", 88,
               "Experiment: 3D animated hero",
               author: myLogin, tabs: [.created],
               closed: true, decision: nil, ci: .success,
               mergeable: true, head: "experiment/3d-hero",
               adds: 540, dels: 12,
               updated: ago(1400)),

            pr("demo-d4", "dash0hq/otel-collector", 55,
               "Fix flaky processor test",
               author: "lena", tabs: [.forMe],
               merged: true, decision: .approved, ci: .success, reviewCount: 1,
               requestedReviewers: [myLogin],
               mergeable: true, head: "fix/flaky-processor-test",
               adds: 24, dels: 18,
               updated: ago(1100)),
        ]

        return (open: created + forMe, done: done)
    }
}

private extension PRSnapshot {
    /// Returns a copy with the Vercel preview pre-populated (and marked checked at
    /// the current `updatedAt`, so the poller's enrichment pass skips it and the
    /// badge shows immediately). No-op when `url` is nil.
    func withPreview(_ url: String?) -> PRSnapshot {
        guard let url else { return self }
        var copy = self
        copy.vercelPreviewUrl = url
        copy.vercelPreviewCheckedAt = updatedAt
        return copy
    }
}
