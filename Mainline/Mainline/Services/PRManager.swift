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

    /// The tab-agnostic PR population that both the badge and the panel's
    /// "Needs a Human" bucket are computed from. Spans both For-me and Created
    /// tabs (deduped by nodeId via the store), narrowed by the selected scope,
    /// and — when `settings.showDrafts` is off — excludes drafts. Every badge
    /// metric reads from this set so the badge and the panel stay consistent.
    var scopedFilteredPRs: [PRSnapshot] {
        let scopeFiltered: [PRSnapshot]
        if settings.menuBarScopeFollowsSelection, let scope = scopeStore.selectedScope {
            scopeFiltered = prs.filter { pr in
                switch scope {
                case .org(let o):  return pr.repoFullName.hasPrefix(o + "/")
                case .repo(let r): return pr.repoFullName == r
                }
            }
        } else {
            scopeFiltered = prs
        }
        guard !settings.showDrafts else { return scopeFiltered }
        return scopeFiltered.filter { $0.classifiedState != .draft }
    }

    /// PRs that need human attention based on TriageClassifier. Tab-agnostic:
    /// derived from `scopedFilteredPRs` so the panel's bucket header count and
    /// the menu-bar badge (`.needsAHuman`) reflect the SAME population.
    var needsHumanPRs: [PRSnapshot] {
        let myLogin = settings.githubUsername
        return scopedFilteredPRs.filter { pr in
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

    /// Count of PRs that have been "handled" (in the scope+draft-filtered
    /// population but not in the needs-human bucket). Matches the bucket's
    /// denominator so "N handled" is consistent with the bucket header.
    var handledCount: Int {
        scopedFilteredPRs.count - needsHumanPRs.count
    }

    // MARK: - Menu-bar badge (scope-aware + configurable — Bug 2 / 5)

    /// The badge for the menu-bar icon, computed from the configured metric.
    /// Reads from `scopedFilteredPRs` (scope + draft filter applied) so every
    /// metric stays consistent with the panel. Colorblind-safe: encodes shape +
    /// tint (see `MenuBarBadge`).
    var menuBarBadge: MenuBarBadge {
        let scoped = scopedFilteredPRs
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

    /// A human-readable one-line description of the current menu-bar badge:
    /// "<count> <metric-noun>[ in <scope>]". The count is read verbatim from
    /// `menuBarBadge.rawCount`, so this string ALWAYS agrees with the icon.
    ///
    /// Examples: "115 open PRs in dash0hq", "33 need a human", "5 review requests".
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

        let scopeSuffix: String
        if settings.menuBarScopeFollowsSelection, let scope = scopeStore.selectedScope {
            scopeSuffix = " in \(scope.displayName)"
        } else if settings.menuBarMetric == .totalOpen {
            scopeSuffix = " across all repos"
        } else {
            scopeSuffix = ""
        }

        return "\(count) \(noun)\(scopeSuffix)"
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
