import Foundation
import Combine

// MARK: - WriteAction

/// All write-path actions available in the triage deck.
enum WriteAction {
    case approve(PRSnapshot)
    case merge(PRSnapshot)
    case requestChanges(PRSnapshot)
    case snooze(PRSnapshot, until: Date)
    case markSeen(PRSnapshot)
    case dismiss(PRSnapshot)
}

// MARK: - PRManager

/// @MainActor orchestrator that owns all services and drives the polling lifecycle.
/// Exposed to SwiftUI views via @StateObject.
@MainActor
final class PRManager: ObservableObject {
    // MARK: - Published state (consumed by MenuBarView)

    @Published var prs: [PRSnapshot] = []
    @Published var statusMessage: String = "Starting…"
    @Published var hasToken: Bool = false
    @Published var tokenInvalid: Bool = false
    @Published var isRefreshing: Bool = false

    /// True once the poller has been started. Guards `start()` against being
    /// invoked twice (label `.task` + popover-content `.task`) which would
    /// otherwise spawn a second poll loop or re-request authorization.
    private var didStart: Bool = false

    /// PRs the user has not yet looked at. Persisted across launches.
    @Published var unreadPRIds: Set<String> = []

    // MARK: - Services (internal for Settings access)

    let store:          PRStateStore
    let notifications:  NotificationService
    let client:         GitHubClient
    private let poller: PRPoller
    let settings:       MainlineSettings
    let trustLedger:    TrustLedgerStore
    let snoozeStore:    SnoozeStore
    let scopeStore:     ScopeStore

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Triage Cockpit computed properties

    /// The SINGLE population that drives the visible browse list AND the
    /// menu-bar badge, so the two can never disagree. Applies, in order:
    ///   1. the selected tab (`tabs.contains(settings.selectedTab)`),
    ///   2. the selected scope (`scopeStore.selectedScope`, nil = All),
    ///   3. the draft filter (excludes `.draft` when `!settings.showDrafts`),
    ///   4. the For-me Direct/Team sub-filter (only on the For-me tab).
    /// `MenuBarView.visiblePRs` delegates to this exact computation.
    ///
    /// This is the "follow current view" set. Every badge metric reads from it
    /// when `menuBarScopeFollowsSelection` is ON. Not sorted here — callers that
    /// render sort via `PRSnapshot.triageOrder`; counting doesn't need order.
    var currentViewPRs: [PRSnapshot] {
        // 1. Tab.
        let tabFiltered = prs.filter { $0.tabs.contains(settings.selectedTab) }

        // 2. Scope.
        let scopeFiltered: [PRSnapshot]
        if let scope = scopeStore.selectedScope {
            scopeFiltered = tabFiltered.filter { pr in
                switch scope {
                case .org(let o):  return pr.repoFullName.hasPrefix(o + "/")
                case .repo(let r): return pr.repoFullName == r
                }
            }
        } else {
            scopeFiltered = tabFiltered
        }

        // 3. Drafts.
        let draftFiltered = settings.showDrafts
            ? scopeFiltered
            : scopeFiltered.filter { $0.classifiedState != .draft }

        // 4. For-me Direct/Team sub-filter (only on the For-me tab; `.all` no-op).
        guard settings.selectedTab == .forMe, settings.forMeReviewFilter != .all else {
            return draftFiltered
        }
        let myLogin = settings.githubUsername
        return draftFiltered.filter { pr in
            switch settings.forMeReviewFilter {
            case .all:    return true
            case .direct: return pr.reviewRequestSource(myLogin: myLogin) == .direct
            case .team:   return pr.reviewRequestSource(myLogin: myLogin) == .team
            }
        }
    }

    /// The population every badge metric counts over. When "Follow current view"
    /// is ON (default), this is `currentViewPRs` (tab + scope + drafts + For-me
    /// sub-filter) so the badge equals what the panel shows. When OFF, it is the
    /// full `prs` list (global, ignoring tab/scope/drafts).
    private var badgeBasePRs: [PRSnapshot] {
        settings.menuBarScopeFollowsSelection ? currentViewPRs : prs
    }

    /// PRs that need human attention based on TriageClassifier, computed over
    /// `badgeBasePRs` so the `.needsAHuman` badge follows the current view (tab +
    /// scope + drafts + For-me sub-filter) when follow-view is on, or all PRs when
    /// off. The panel's own bucket is tab-scoped separately in `MenuBarView`.
    var needsHumanPRs: [PRSnapshot] {
        let myLogin = settings.githubUsername
        return badgeBasePRs.filter { pr in
            let tier = trustLedger.tier(for: pr.author)
            return TriageClassifier.needsHuman(
                pr,
                myLogin: myLogin,
                trustTier: tier,
                includeConflicts: settings.includeConflictsInNeedsHuman
            )
        }
        .sorted(by: PRSnapshot.triageOrder)
    }

    /// Count of PRs that need a human. Single source of truth for the badge
    /// (`.needsAHuman`) and the panel bucket header.
    var needsHumanCount: Int { needsHumanPRs.count }

    /// Count of PRs the user personally needs to act on (Layer A badge logic).
    /// - Authored PR with failing CI  → merge blocker
    /// - Review requested + CI success/pending → needs review
    var needsYouCount: Int {
        let myLogin = settings.githubUsername
        guard !myLogin.isEmpty else { return 0 }
        return prs.filter { pr in
            let isMyPR = pr.author == myLogin
            let reviewRequested = pr.tabs.contains(.forMe) && pr.requestedReviewers.contains(myLogin)
            // Merge blocker: my PR with failing CI
            if isMyPR && (pr.ciStatus == .failure || pr.ciStatus == .error) { return true }
            // Review needed: I'm requested + CI is ready
            if reviewRequested && (pr.ciStatus == .success || pr.ciStatus == .unknown) { return true }
            return false
        }.count
    }

    /// Count of PRs that have been "handled" (in the badge-base population but not
    /// in the needs-human bucket). Matches the same denominator as `needsHumanPRs`.
    var handledCount: Int {
        badgeBasePRs.count - needsHumanPRs.count
    }

    // MARK: - Menu-bar badge (scope-aware + configurable — Bug 2 / 5)

    /// The badge for the menu-bar icon, computed from the configured metric.
    /// Reads from `badgeBasePRs` — i.e. the current view (tab + scope + drafts +
    /// For-me sub-filter) when "Follow current view" is on, else all PRs — so the
    /// badge matches the visible list. With the `.totalOpen` metric the badge
    /// equals the visible open count. Colorblind-safe: encodes shape + tint.
    var menuBarBadge: MenuBarBadge {
        let scoped = badgeBasePRs
        let myLogin = settings.githubUsername

        switch settings.menuBarMetric {
        case .needsAHuman:
            // Reuses the exact same set the panel's bucket shows.
            return .attention(needsHumanCount)

        case .failingCI:
            let count = scoped.filter { pr in
                pr.classifiedState != .merged && pr.classifiedState != .closed &&
                (pr.ciStatus == .failure || pr.ciStatus == .error)
            }.count
            return .blocker(count)

        case .reviewRequests:
            guard !myLogin.isEmpty else { return .attention(0) }
            let count = scoped.filter { pr in
                pr.tabs.contains(.forMe) && pr.requestedReviewers.contains(myLogin)
            }.count
            return .attention(count)

        case .unread:
            let count = scoped.filter { unreadPRIds.contains($0.nodeId) }.count
            return .attention(count)

        case .totalOpen:
            let count = scoped.filter {
                $0.classifiedState != .merged && $0.classifiedState != .closed
            }.count
            return .neutral(count)
        }
    }

    /// A human-readable one-line description of the current menu-bar badge. The
    /// count is read verbatim from `menuBarBadge.rawCount` (which reads the SAME
    /// `badgeBasePRs`), so this string ALWAYS agrees with the icon.
    ///
    /// When "Follow current view" is on, it reflects the tab (and scope) context:
    ///   "5 open PRs · Created · dash0hq", "93 review requests · For me · dash0hq".
    /// When off, it describes the global metric: "115 open PRs across all repos".
    var badgeExplanation: String {
        let count = menuBarBadge.rawCount

        let noun: String
        switch settings.menuBarMetric {
        case .needsAHuman:    noun = "need a human"
        case .failingCI:      noun = "with failing CI"
        case .reviewRequests: noun = "review requests"
        case .unread:         noun = "unread"
        case .totalOpen:      noun = "open PRs"
        }

        var parts = ["\(count) \(noun)"]

        if settings.menuBarScopeFollowsSelection {
            // Follow current view: annotate with the tab and (if any) the scope.
            parts.append(settings.selectedTab.title)
            if let scope = scopeStore.selectedScope {
                parts.append(scope.displayName)
            }
        } else if settings.menuBarMetric == .totalOpen {
            parts[0] += " across all repos"
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Init

    init(settings: MainlineSettings = .shared) {
        self.settings      = settings
        self.store         = PRStateStore()
        self.notifications = NotificationService()
        self.client        = GitHubClient(settings: settings)
        self.trustLedger   = TrustLedgerStore()
        self.snoozeStore   = SnoozeStore(settings: settings)
        self.scopeStore    = ScopeStore()
        self.poller        = PRPoller(
            client:        GitHubClient(settings: settings),
            store:         store,
            notifications: notifications,
            settings:      settings
        )

        // Mirror store updates to prs
        store.$snapshots
            .map { dict in dict.values.sorted { $0.updatedAt > $1.updatedAt } }
            .assign(to: &$prs)

        // Surface the poller's real status (poll results, auth/rate-limit errors)
        // in the header. Without this the header is stuck on the last start() value.
        poller.$statusMessage
            .assign(to: &$statusMessage)

        // Load persisted unread IDs
        unreadPRIds = Set(settings.unreadPRIdsList)

        // Observe quiet transitions from the poller (all transition nodeIds)
        NotificationCenter.default.addObserver(
            forName: .mainlineQuietTransitions,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let nodeIds = notification.userInfo?["nodeIds"] as? [String] else { return }
            self.unreadPRIds.formUnion(nodeIds)
            self.settings.unreadPRIdsList = Array(self.unreadPRIds)
        }

        // Rebuild scope counts after every PR update
        store.$snapshots
            .map { dict in Array(dict.values) }
            .sink { [weak self] prs in
                self?.scopeStore.rebuild(from: prs)
            }
            .store(in: &cancellables)
    }

    // MARK: - Token lifecycle

    func start() async {
        // Idempotent: the always-rendered menu-bar label and the popover
        // content both attach a `.task { await manager.start() }`. Only the
        // first call should spin up the poller.
        guard !didStart else { return }
        didStart = true

        notifications.requestAuthorization()
        await trustLedger.load()

        let token = await KeychainHelper.loadToken()
        if let token, !token.isEmpty {
            hasToken = true
            tokenInvalid = false
            poller.start(token: token)
        } else {
            hasToken = false
            statusMessage = "Not configured — open Settings"
        }
    }

    func restart() async {
        poller.stop()
        // Allow start() to run again after an explicit restart (e.g. token change).
        didStart = false
        await start()
    }

    /// Triggers a single poll without restarting the timer loop.
    /// Used by the Refresh button — does NOT restart the poller.
    func triggerSingleRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let token = await KeychainHelper.loadToken()
        guard let token, !token.isEmpty else {
            statusMessage = "Not configured — open Settings"
            return
        }
        await poller.pollOnce(token: token)
    }

    func stop() {
        poller.stop()
    }

    // MARK: - Write actions

    /// Dispatches a write action. Write actions are gated by `settings.writeActionsEnabled`.
    func performAction(_ action: WriteAction) async {
        guard let token = await KeychainHelper.loadToken(), !token.isEmpty else { return }

        switch action {
        case .approve(let pr):
            do {
                try await client.approvePR(nodeId: pr.nodeId, token: token)
                let verdict = VerdictRecord(
                    prNodeId: pr.nodeId,
                    author: pr.author,
                    verdict: .merged,
                    date: Date(),
                    linesChanged: pr.totalLines,
                    hadTests: false
                )
                trustLedger.recordVerdict(verdict, for: pr.author)
            } catch {
                statusMessage = "Approve failed: \(error.localizedDescription)"
            }

        case .merge(let pr):
            do {
                try await client.mergePR(nodeId: pr.nodeId, token: token)
                let verdict = VerdictRecord(
                    prNodeId: pr.nodeId,
                    author: pr.author,
                    verdict: .merged,
                    date: Date(),
                    linesChanged: pr.totalLines,
                    hadTests: false
                )
                trustLedger.recordVerdict(verdict, for: pr.author)
            } catch {
                statusMessage = "Merge failed: \(error.localizedDescription)"
            }

        case .requestChanges(let pr):
            do {
                try await client.requestChangesPR(nodeId: pr.nodeId, body: "", token: token)
                let verdict = VerdictRecord(
                    prNodeId: pr.nodeId,
                    author: pr.author,
                    verdict: .changesRequested,
                    date: Date(),
                    linesChanged: pr.totalLines,
                    hadTests: false
                )
                trustLedger.recordVerdict(verdict, for: pr.author)
            } catch {
                statusMessage = "Request changes failed: \(error.localizedDescription)"
            }

        case .snooze(let pr, let until):
            snoozeStore.snooze(pr, until: until)

        case .markSeen(let pr):
            // Mark seen is a local operation — no API call needed
            _ = pr

        case .dismiss(let pr):
            // Dismiss removes from visible list locally until next poll
            _ = pr
        }
    }

    // MARK: - Autopilot

    /// Checks if a PR qualifies for autopilot auto-approve and fires if so.
    /// Double-gated: requires both autopilotEnabled AND writeActionsEnabled.
    func checkAutopilot(for pr: PRSnapshot) async {
        guard settings.autopilotEnabled, settings.writeActionsEnabled else { return }

        let tier = trustLedger.tier(for: pr.author)
        guard tier == .autopilot else { return }
        guard pr.ciStatus == .success else { return }
        guard pr.totalLines < 50 else { return }

        await performAction(.approve(pr))
    }

    // MARK: - Unread management

    /// Marks a single PR as seen (removes from unread).
    func markSeen(_ pr: PRSnapshot) {
        unreadPRIds.remove(pr.nodeId)
        settings.unreadPRIdsList = Array(unreadPRIds)
    }

    /// Marks all currently visible PRs as seen.
    func markAllSeen() {
        unreadPRIds.removeAll()
        settings.unreadPRIdsList = []
    }

    // MARK: - Fetch username after token save

    func fetchUsername(token: String) async {
        guard let url = URL(string: "https://api.github.com/user") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        struct UserResponse: Decodable { let login: String }
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let user = try? JSONDecoder().decode(UserResponse.self, from: data) {
            settings.githubUsername = user.login
        }
    }
}
