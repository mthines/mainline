import Foundation
import Combine
import AppKit

// MARK: - WriteAction

/// All write-path actions available in the triage deck.
enum WriteAction {
    case approve(PRSnapshot)
    case merge(PRSnapshot)
    case requestChanges(PRSnapshot)
    case snooze(PRSnapshot, until: Date)
    case unsnooze(PRSnapshot)
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

    /// DISPLAY-ONLY recently-completed PRs (merged / closed-not-merged), populated
    /// each poll by `PRPoller.fetchDonePRs` via the `onDonePRs` sink. These are
    /// kept ENTIRELY separate from `prs` (which is the open, diff-engine-backed
    /// set): they never pass through `PRStateStore` / `PRDiffEngine` /
    /// notifications, never affect the badge / needs-attention counts, and never
    /// fire a "new PR" banner. Rendered only in the collapsed "Done" section.
    @Published var donePRs: [PRSnapshot] = []

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

    /// The PR whose peek overlay is currently shown (Space / "View Details"), or
    /// `nil` when no peek is open. Lifted out of `TriageDeckView` so the overlay
    /// can be presented at the panel level in `MenuBarView` — a modal peek belongs
    /// above the whole popover, not anchored inside the scrolling deck content,
    /// so it can use the full panel height instead of the short deck's bounds.
    @Published var peekPR: PRSnapshot?

    /// The undo toast stack. Owned here (not in `TriageDeckView`) so the toast can
    /// be presented at the PANEL level — pinned to the true bottom of the popover —
    /// rather than inside the scrolling deck, where it floated up to the content's
    /// bottom whenever the list was shorter than the panel. `TriageDeckView` still
    /// pushes/undoes entries; `MenuBarView` renders them.
    @Published var undoEntries: [UndoEntry] = []

    // MARK: - Services (internal for Settings access)

    let store:          PRStateStore
    let notifications:  NotificationService
    let client:         GitHubClient
    private let poller: PRPoller
    let settings:       MainlineSettings
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
    ///
    /// Snoozed (postponed) PRs are EXCLUDED here — a PR with a future
    /// `snoozeMap[nodeId]` leaves every actionability group AND drops from the
    /// badge / needs-attention count. The "Postponed" list section renders them
    /// separately via `postponedPRs`, which deliberately ignores this exclusion.
    var currentViewPRs: [PRSnapshot] {
        tabScopeFilteredPRs.filter { !snoozeStore.snoozedNodeIds.contains($0.nodeId) }
    }

    /// The current tab + scope + drafts + For-me sub-filter population, BEFORE the
    /// snooze exclusion. Shared by `currentViewPRs` (which then drops snoozed) and
    /// `postponedPRs` (which keeps only the snoozed ones). Not sorted.
    private var tabScopeFilteredPRs: [PRSnapshot] {
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

    /// Currently-snoozed PRs for the current tab + scope (+ drafts + For-me
    /// sub-filter) — the membership of the "Postponed" list section. This is the
    /// complement of `currentViewPRs` within `tabScopeFilteredPRs`: it KEEPS only
    /// the PRs excluded by the snooze filter, which is the section's whole purpose.
    var postponedPRs: [PRSnapshot] {
        let snoozed = snoozeStore.snoozedNodeIds
        return tabScopeFilteredPRs.filter { snoozed.contains($0.nodeId) }
    }

    /// The DISPLAY-ONLY "Done" set (recently merged/closed) for the current tab +
    /// scope — the membership of the collapsed "Done" section. Filters `donePRs`
    /// (never `prs`) by the selected tab and scope only: the drafts filter and the
    /// For-me Direct/Team sub-filter don't apply to completed PRs (a closed PR is
    /// not a draft; review-request source is moot once merged/closed). Snooze does
    /// not apply either. Not sorted here — the view sorts by `updatedAt` desc.
    var doneViewPRs: [PRSnapshot] {
        // Tab.
        let tabFiltered = donePRs.filter { $0.tabs.contains(settings.selectedTab) }
        // Scope.
        guard let scope = scopeStore.selectedScope else { return tabFiltered }
        return tabFiltered.filter { pr in
            switch scope {
            case .org(let o):  return pr.repoFullName.hasPrefix(o + "/")
            case .repo(let r): return pr.repoFullName == r
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

    /// PRs that need attention — the SINGLE "needs attention" concept. Uses the one
    /// shared predicate `PRSnapshot.needsAttention` (CI failing / changes requested /
    /// unresolved threads), the same one the browse list's "Needs attention"
    /// (`ActionGroup.needsAttention`) group uses, computed over `badgeBasePRs` so the
    /// badge follows the current view (tab + scope + drafts + For-me sub-filter) when
    /// follow-view is on, or all PRs when off. The list group counts over
    /// `currentViewPRs`; with follow-view on (the default) `badgeBasePRs ==
    /// currentViewPRs`, so the badge and the list group agree.
    var needsAttentionPRs: [PRSnapshot] {
        badgeBasePRs
            .filter { $0.needsAttention }
            .sorted(by: PRSnapshot.triageOrder)
    }

    /// Count of PRs that need attention. Single source of truth for the badge's
    /// `.needsAHuman` metric.
    var needsAttentionCount: Int { needsAttentionPRs.count }

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
            // Reuses the exact same "needs attention" predicate the browse list's
            // "Needs attention" group uses (over the same base population).
            return .attention(needsAttentionCount)

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
        case .needsAHuman:    noun = "need attention"
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
        self.snoozeStore   = SnoozeStore(settings: settings)
        self.scopeStore    = ScopeStore()
        self.poller        = PRPoller(
            client:        GitHubClient(settings: settings),
            store:         store,
            notifications: notifications,
            settings:      settings
        )

        // Receive the display-only Done set from the poller. Assigned on the main
        // actor (poller is @MainActor); stored separately from `prs` so it never
        // reaches the diff engine, notifications, or any badge/attention count.
        poller.onDonePRs = { [weak self] done in
            self?.donePRs = done
        }

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
        // Load the persisted snapshot baseline BEFORE the first poll so the diff
        // engine compares against last-known state instead of an empty set (which
        // would fire a "New PR" banner for every open PR on launch).
        await store.load()

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
        // Local, no-network actions run without a token so postpone / resume /
        // mark-seen / dismiss always work even before the PAT is loaded.
        switch action {
        case .snooze(let pr, let until):
            snoozeStore.snooze(pr, until: until)
            TelemetryService.shared.recordTriageInteraction("snooze")
            return
        case .unsnooze(let pr):
            snoozeStore.unsnooze(nodeId: pr.nodeId)
            TelemetryService.shared.recordTriageInteraction("unsnooze")
            return
        case .markSeen:
            TelemetryService.shared.recordTriageInteraction("mark_seen")
            return
        case .dismiss:
            TelemetryService.shared.recordTriageInteraction("dismiss")
            return
        default:
            break
        }

        guard let token = await KeychainHelper.loadToken(), !token.isEmpty else { return }

        switch action {
        case .approve(let pr):
            let actionStart = Date()
            do {
                try await client.approvePR(nodeId: pr.nodeId, token: token)
                TelemetryService.shared.recordWriteAction(
                    "approve",
                    mergeMethod: nil,
                    result: "success",
                    duration: Date().timeIntervalSince(actionStart),
                    failureCategory: nil
                )
            } catch {
                statusMessage = "Approve failed: \(error.localizedDescription)"
                TelemetryService.shared.recordWriteAction(
                    "approve",
                    mergeMethod: nil,
                    result: "failure",
                    duration: Date().timeIntervalSince(actionStart),
                    failureCategory: "api_error"
                )
                Self.presentActionFailure("Approve failed", error: error)
            }

        case .merge(let pr):
            let actionStart = Date()
            let resolvedMergeMethod = resolvedMergeMethodString(for: pr)
            do {
                try await client.mergePR(pr: pr, preference: settings.mergeMethodPreference, token: token)
                TelemetryService.shared.recordWriteAction(
                    "merge",
                    mergeMethod: resolvedMergeMethod,
                    result: "success",
                    duration: Date().timeIntervalSince(actionStart),
                    failureCategory: nil
                )
            } catch {
                statusMessage = "Merge failed: \(error.localizedDescription)"
                TelemetryService.shared.recordWriteAction(
                    "merge",
                    mergeMethod: resolvedMergeMethod,
                    result: "failure",
                    duration: Date().timeIntervalSince(actionStart),
                    failureCategory: "api_error"
                )
                Self.presentActionFailure("Merge failed", error: error)
            }

        case .requestChanges(let pr):
            let actionStart = Date()
            do {
                try await client.requestChangesPR(nodeId: pr.nodeId, body: "", token: token)
                TelemetryService.shared.recordWriteAction(
                    "request_changes",
                    mergeMethod: nil,
                    result: "success",
                    duration: Date().timeIntervalSince(actionStart),
                    failureCategory: nil
                )
            } catch {
                statusMessage = "Request changes failed: \(error.localizedDescription)"
                TelemetryService.shared.recordWriteAction(
                    "request_changes",
                    mergeMethod: nil,
                    result: "failure",
                    duration: Date().timeIntervalSince(actionStart),
                    failureCategory: "api_error"
                )
                Self.presentActionFailure("Request changes failed", error: error)
            }

        case .snooze, .unsnooze, .markSeen, .dismiss:
            // Handled above as local, no-network actions before the token guard.
            break
        }

        // Reflect the change immediately: after a successful write action a merged
        // PR should leave the open groups (and surface under "Done") without waiting
        // for the next scheduled poll — otherwise the action looks like it did
        // nothing even though GitHub performed it.
        await triggerSingleRefresh()
    }

    /// Returns the resolved merge method string for telemetry — uses the same logic
    /// as `GitHubClient.resolveMergeMethod` but returns a lowercase string.
    /// Never includes PR titles, repo names, or author logins.
    private func resolvedMergeMethodString(for pr: PRSnapshot) -> String {
        let method = GitHubClient.resolveMergeMethod(for: pr, preference: settings.mergeMethodPreference)
        switch method {
        case .squash: return "squash"
        case .rebase: return "rebase"
        case .merge:  return "merge"
        }
    }

    /// Presents an app-modal NSAlert describing a failed write action. The popover
    /// closes on action, so `statusMessage` is never seen — an alert is the only
    /// way the real GitHub error reaches the user. Benign cancellations (popover
    /// closed mid-request) are suppressed. Runs on the main actor.
    private static func presentActionFailure(_ title: String, error: Error) {
        if case GitHubAPIError.cancelled = error { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
