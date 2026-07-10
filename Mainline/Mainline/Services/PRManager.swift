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

    // MARK: - Inbox derived populations

    /// The mute configuration built from current settings. Rebuilt on each access
    /// (cheap — it just reads @Published values); no caching needed.
    var inboxMuteConfig: InboxMuteConfig {
        InboxMuteConfig(
            mutePatterns:       settings.mutePatterns,
            muteBotAuthors:     settings.muteBotAuthors,
            reviewFocusAuthors: settings.reviewFocusAuthors,
            reviewFocusTeams:   settings.reviewFocusTeams,
            muteLabels:         settings.muteLabels,
            myLogin:            settings.githubUsername
        )
    }

    /// Union of all PRs from the two polling tabs (.forMe + .created), filtered
    /// through the standard scope + drafts guards (snooze excluded). This is the
    /// Inbox population BEFORE mute rules are applied.
    private var inboxUnionPRs: [PRSnapshot] {
        let snoozed = snoozeStore.snoozedNodeIds
        // A PR can appear in both tabs (union by nodeId, keeping the last-merged copy).
        var seen = Set<String>()
        return prs.filter {
            ($0.tabs.contains(.forMe) || $0.tabs.contains(.created))
                && !snoozed.contains($0.nodeId)
        }.filter { pr in
            guard seen.insert(pr.nodeId).inserted else { return false }
            return true
        }
    }

    /// Non-muted union for the Inbox, WITHOUT the scope filter. This is the base
    /// the scope chips derive from (so each org chip can show its own count and the
    /// chip row is always populated on the Inbox tab — mirrors how the other tabs
    /// use `tabFiltered(applyScope: false)`).
    private var inboxActiveUnscopedPRs: [PRSnapshot] {
        let config = inboxMuteConfig
        return inboxUnionPRs.filter { !effectiveMuted($0, config: config) }
    }

    /// Non-muted PRs for the Inbox (active), with the selected scope applied —
    /// grouped ready for role-section rendering. Muted PRs surface in
    /// `inboxMutedPRs` instead.
    var inboxActivePRs: [PRSnapshot] {
        applyingSelectedScope(inboxActiveUnscopedPRs)
    }

    /// Muted PRs for the Inbox (demoted by a rule OR a manual override), with the
    /// selected scope applied — rendered in the collapsed "Muted / low-priority" group.
    var inboxMutedPRs: [PRSnapshot] {
        let config = inboxMuteConfig
        return applyingSelectedScope(inboxUnionPRs.filter { effectiveMuted($0, config: config) })
    }

    // MARK: - Inbox mute: rules + manual override

    /// Pure rule-based mute verdict (ignores manual overrides).
    private func ruleMuted(_ pr: PRSnapshot, config: InboxMuteConfig) -> Bool {
        let role = pr.inboxRole(myLogin: config.myLogin)
        return InboxMuteEngine.muteVerdict(
            title:          pr.title,
            headRef:        pr.headRefName,
            authorLogin:    pr.author,
            authorIsBot:    pr.authorIsBot,
            requestedTeams: pr.requestedTeams,
            labels:         pr.labels,
            role:           role,
            config:         config
        ) != nil
    }

    /// Effective muted state: a manual override (`settings.inboxMuteOverrides`)
    /// wins over the rules — `true` forces Muted, `false` pins the PR active even
    /// when a rule matches. Absent → follow the rules.
    private func effectiveMuted(_ pr: PRSnapshot, config: InboxMuteConfig) -> Bool {
        if let override = settings.inboxMuteOverrides[pr.nodeId] { return override }
        return ruleMuted(pr, config: config)
    }

    /// Public accessor for the current effective muted state (used by the deck's
    /// toggle-mute verb to decide the direction of the toggle).
    func isInboxMuted(_ pr: PRSnapshot) -> Bool {
        effectiveMuted(pr, config: inboxMuteConfig)
    }

    /// The stored manual override for a PR (nil = following the rules). Exposed so
    /// the toggle verb can capture the prior value for undo.
    func inboxMuteOverride(for pr: PRSnapshot) -> Bool? {
        settings.inboxMuteOverrides[pr.nodeId]
    }

    /// Sets (or, with `nil`, clears) the manual override for a PR.
    func setInboxMuteOverride(_ value: Bool?, for pr: PRSnapshot) {
        if let value {
            settings.inboxMuteOverrides[pr.nodeId] = value
        } else {
            settings.inboxMuteOverrides.removeValue(forKey: pr.nodeId)
        }
    }

    /// Toggles a PR between the active list and the Muted group by writing a manual
    /// override opposite to its current effective state. Returns the new muted state.
    @discardableResult
    func toggleInboxMute(_ pr: PRSnapshot) -> Bool {
        let newMuted = !isInboxMuted(pr)
        settings.inboxMuteOverrides[pr.nodeId] = newMuted
        return newMuted
    }

    /// Applies the currently-selected scope (nil = All) to an Inbox PR list.
    private func applyingSelectedScope(_ list: [PRSnapshot]) -> [PRSnapshot] {
        guard let scope = scopeStore.selectedScope else { return list }
        return list.filter { Self.pr($0, matches: scope) }
    }

    // MARK: - Current view (drives badge + visible list)

    /// The SINGLE population that drives the visible browse list AND the
    /// menu-bar badge, so the two can never disagree. Applies, in order:
    ///   1. the selected tab (`tabs.contains(settings.selectedTab)`),
    ///   2. the selected scope (`scopeStore.selectedScope`, nil = All),
    ///   3. the draft filter (excludes `.draft` when `!settings.showDrafts`),
    ///   4. the For-me Direct/Team sub-filter (only on the For-me tab).
    ///
    /// On the Inbox tab, returns `inboxActivePRs` (non-muted union), so the badge
    /// counts only non-muted PRs. Muted PRs are excluded upstream.
    ///
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
        // Inbox tab routes to the mute-filtered active set (snooze already excluded
        // in inboxUnionPRs → inboxActivePRs). For the other tabs, keep the existing
        // snooze-excluded tab/scope/drafts/for-me pipeline.
        if settings.selectedTab == .inbox {
            return inboxActivePRs
        }
        return tabScopeFilteredPRs.filter { !snoozeStore.snoozedNodeIds.contains($0.nodeId) }
    }

    /// The current tab + scope + drafts + For-me sub-filter population, BEFORE the
    /// snooze exclusion. Shared by `currentViewPRs` (which then drops snoozed) and
    /// `postponedPRs` (which keeps only the snoozed ones). Not sorted.
    private var tabScopeFilteredPRs: [PRSnapshot] {
        tabFiltered(applyScope: true)
    }

    /// Tab + drafts + For-me sub-filter applied to `prs`. The scope filter is
    /// applied only when `applyScope` is true; the scope-chip base
    /// (`scopeSelectorBasePRs`) omits it so each chip can show its own count.
    /// Snooze is NOT applied here.
    ///
    /// The Inbox tab is handled in `currentViewPRs` (which routes to
    /// `inboxActivePRs`). This private helper is only called for `.forMe` /
    /// `.created`, but we guard on it to be safe.
    private func tabFiltered(applyScope: Bool) -> [PRSnapshot] {
        // Inbox tab uses a separate pipeline — callers should not reach here on .inbox,
        // but guard defensively to avoid an accidental empty result.
        guard settings.selectedTab != .inbox else { return [] }

        // 1. Tab.
        var result = prs.filter { $0.tabs.contains(settings.selectedTab) }

        // 2. Scope (optional).
        if applyScope, let scope = scopeStore.selectedScope {
            result = result.filter { Self.pr($0, matches: scope) }
        }

        // 3. Drafts.
        if !settings.showDrafts {
            result = result.filter { $0.classifiedState != .draft }
        }

        // 4. For-me Direct/Team sub-filter (only on the For-me tab; `.all` no-op).
        guard settings.selectedTab == .forMe, settings.forMeReviewFilter != .all else {
            return result
        }
        let myLogin = settings.githubUsername
        return result.filter { pr in
            switch settings.forMeReviewFilter {
            case .all:    return true
            case .direct: return pr.reviewRequestSource(myLogin: myLogin) == .direct
            case .team:   return pr.reviewRequestSource(myLogin: myLogin) == .team
            }
        }
    }

    /// Whether a PR falls under a given scope. Shared by the list filter and the
    /// scope-chip counts so both agree on membership.
    private static func pr(_ pr: PRSnapshot, matches scope: PRScope) -> Bool {
        switch scope {
        case .org(let o):  return pr.repoFullName.hasPrefix(o + "/")
        case .repo(let r): return pr.repoFullName == r
        }
    }

    // MARK: - Scope chips (tab-aware)

    /// The population the scope chips derive from: everything `currentViewPRs`
    /// applies EXCEPT the scope filter itself (tab + drafts + For-me + snooze
    /// exclusion). So a chip's number equals what you'd see in the deck if you
    /// selected that scope on the current tab.
    private var scopeSelectorBasePRs: [PRSnapshot] {
        // Inbox uses its own union pipeline (tabFiltered short-circuits to [] on
        // .inbox), so derive the chip base from the non-muted, scope-independent
        // Inbox set — otherwise the chips vanish whenever no scope is selected.
        if settings.selectedTab == .inbox {
            return inboxActiveUnscopedPRs
        }
        return tabFiltered(applyScope: false)
            .filter { !snoozeStore.snoozedNodeIds.contains($0.nodeId) }
    }

    /// Per-org counts for the scope chips, matching the visible list. Previously
    /// the chips counted the full `prs` across BOTH tabs, so a chip could read
    /// "dash0hq 115" while the current tab's list was empty ("Queue clear"). These
    /// counts follow the selected tab, drafts, For-me, and snooze filters.
    var scopeCounts: [PRScope: Int] {
        var counts: [PRScope: Int] = [:]
        for pr in scopeSelectorBasePRs {
            guard let owner = pr.repoFullName.split(separator: "/", maxSplits: 1)
                .first.map(String.init) else { continue }
            counts[.org(owner), default: 0] += 1
        }
        return counts
    }

    /// Scope chips to show: every org present on the current tab (count > 0),
    /// ordered by count descending then name — plus the selected scope even when
    /// it has 0 on this tab, so its chip stays visible and highlighted. Cross-poll
    /// selection invalidation still lives in `ScopeStore.rebuild`.
    var availableScopes: [PRScope] {
        let counts = scopeCounts
        var scopes = Array(counts.keys)
        if let sel = scopeStore.selectedScope, !scopes.contains(sel) {
            scopes.append(sel)
        }
        return scopes.sorted {
            let c1 = counts[$0] ?? 0
            let c2 = counts[$1] ?? 0
            if c1 != c2 { return c1 > c2 }
            return $0.displayName < $1.displayName
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
