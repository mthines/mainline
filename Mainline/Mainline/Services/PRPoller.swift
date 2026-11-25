import Foundation

// MARK: - Carry-forward value types

/// Why a tab's result set could not be trusted as the whole tab this poll cycle.
/// Raw values are the bounded `poll.carry_forward_reason` telemetry label.
///
/// File scope, not nested in `PRPoller`: `PRPoller` is `@MainActor`, and
/// `carryingForward` reads `rawValue` from a `nonisolated` context. Keeping these
/// types outside the isolated class removes any question of a nested declaration
/// inheriting that isolation.
enum CarryForwardReason: String, Equatable {
    /// 304, or a 5xx that survived the client-side retry — the tab returned nothing.
    case noData = "no_data"
    /// The post-5xx retry succeeded at the reduced page size — the tab returned a subset.
    case degradedPage = "degraded_page"
}

/// The merged snapshot array plus which PRs the carry-forward rescued, and why.
/// The counts feed `TelemetryService.recordPRsCarriedForward`; each PR is counted
/// exactly ONCE, so the total is a true PR count rather than a per-tab tally that
/// double-counts anything sitting in both tabs.
struct CarryForwardResult: Equatable {
    var snapshots: [PRSnapshot]
    /// nodeId → why it was carried. Fetched PRs never appear here.
    var carriedReasons: [String: CarryForwardReason]

    var carriedByReason: [String: Int] {
        carriedReasons.values.reduce(into: [:]) { $0[$1.rawValue, default: 0] += 1 }
    }
}

/// Task-based poll loop. Cancels cleanly via `stop()`.
/// All state writes go through PRStateStore — PRPoller never mutates snapshots directly.
@MainActor
final class PRPoller {
    private let client:       GitHubClient
    private let store:        PRStateStore
    private let notifications: NotificationService
    private var hooksHavePolledOnce = false
    private let settings:     MainlineSettings

    private var pollingTask: Task<Void, Never>?

    /// Bots whose committed-PR query last completed (see `seedingBots`). In-memory
    /// only: nil until the first poll after launch.
    private var knownCommittedBots: Set<String>?

    /// Whether the popover is open. Set by `PRManager`. Starts false: the app launches
    /// with the panel closed, and a closed panel polls at the slower idle pace.
    var isPanelVisible = false

    /// When the display-only Done searches last ran (see `PollPacing.secondaryInterval`).
    /// Stamped only when they actually ran, so an early-failed poll retries them.
    private var lastDoneAt: Date?

    /// Human-readable status for the menu bar.
    @Published private(set) var statusMessage: String = "Not started"

    /// When the last poll fully succeeded. The popover shows it beside a rate-limit
    /// banner ("showing data from 19:33") so frozen data is never mistaken for fresh.
    /// Persisted so a relaunch during a rate limit still says how old the rows loaded from
    /// disk are — otherwise they would look fresh, which is what the banner exists to prevent.
    @Published private(set) var lastSyncAt: Date? = {
        let t = UserDefaults.standard.double(forKey: "lastFullSyncAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    /// Sink for the DISPLAY-ONLY "Done" set (recently merged/closed PRs), fetched
    /// alongside the open sets each poll but stored SEPARATELY by the caller
    /// (`PRManager.donePRs`). These NEVER pass through `PRStateStore` /
    /// `PRDiffEngine` / notifications, so a merged PR can't fire a "new PR" banner.
    /// Set by `PRManager`; nil = no Done fetch performed.
    /// Second argument: every Done tab answered (a skipped tab means the set is partial).
    var onDonePRs: (([PRSnapshot], Bool) -> Void)?

    /// Issue state, polled alongside the PRs. Set by `PRManager`; nil = no issue fetch.
    var issueStore: IssueStore?

    init(
        client:        GitHubClient,
        store:         PRStateStore,
        notifications: NotificationService,
        settings:      MainlineSettings = .shared
    ) {
        self.client        = client
        self.store         = store
        self.notifications = notifications
        self.settings      = settings
    }

    // MARK: - Lifecycle

    func start(token: String) {
        stop()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            // First poll runs IMMEDIATELY — the sleep is at the END of the loop,
            // never before the first fetch — so launching the app begins fetching
            // right away and populates without the user pressing Refresh.
            while !Task.isCancelled {
                await self.poll(token: token)
                let interval = PollPacing.interval(
                    base: Double(self.settings.pollIntervalSeconds),
                    panelVisible: self.isPanelVisible,
                    budgetLow: APIBudget.shared.isLow
                )
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Public one-shot poll (used by Refresh button)

    /// Runs a single poll without interfering with the scheduled loop.
    /// - Parameter forceDone: also run the Done searches regardless of their cadence
    ///   (Refresh button); a panel-open refresh leaves them on their own schedule.
    func pollOnce(token: String, forceDone: Bool = true) async {
        await poll(token: token, forced: forceDone)
    }

    // MARK: - Carry-forward (pure)

    /// Re-adds the previously known snapshots of every tab whose fetch was
    /// incomplete this cycle and that the fetch did not return.
    ///
    /// `PRStateStore.update` rebuilds its dict from exactly the array it is handed,
    /// and `PRDiffEngine` emits `.newPR` for any nodeId absent from that baseline.
    /// So a PR dropped here does not merely vanish from the panel for one cycle — it
    /// comes back as a brand-new PR on the next complete poll, re-firing its
    /// notification and re-lighting its unread dot. Carrying it forward VERBATIM is
    /// what keeps that from happening: an unchanged snapshot diffs to no transition.
    ///
    /// A PR sitting in two incomplete tabs is attributed to `degradedPage` over
    /// `noData` — the more specific reason, and the one worth watching.
    ///
    /// Pure, `static` and `nonisolated` so `PollCarryForwardChecks` can assert it
    /// from `applicationDidFinishLaunching` — which is not `@MainActor` here — without
    /// a poll loop, a store or the network.
    ///
    /// The committed-PR bot query (`committedPRQuery`) is carried forward by SOURCE,
    /// not by tab: it shares its tab with a regular query, and tagging that whole tab
    /// incomplete whenever the bot query 304s would keep every PR that genuinely left
    /// the regular query alive forever. `incompleteCommittedQuery` instead re-adds only
    /// the previous snapshots that query would have returned (`isCommittedBotPR`).
    nonisolated static func carryingForward(
        fetched: [PRSnapshot],
        previous: [String: PRSnapshot],
        incompleteTabs: [ReviewTab: CarryForwardReason],
        incompleteCommittedQuery: CarryForwardReason? = nil,
        committedBotAuthors: Set<String> = [],
        committedQueryTab: ReviewTab? = nil,
        incompleteDiscovery: CarryForwardReason? = nil,
        isDiscoveredPR: (PRSnapshot) -> Bool = { _ in false }
    ) -> CarryForwardResult {
        guard !incompleteTabs.isEmpty || incompleteCommittedQuery != nil || incompleteDiscovery != nil else {
            return CarryForwardResult(snapshots: fetched, carriedReasons: [:])
        }

        var result = fetched
        var carriedReasons: [String: CarryForwardReason] = [:]
        let fetchedIds = Set(fetched.map(\.nodeId))
        // Sorted for determinism: the store is a dictionary, and an unordered
        // carry-forward would make the merged array's order vary between runs.
        for snapshot in previous.values.sorted(by: { $0.nodeId < $1.nodeId })
        where !fetchedIds.contains(snapshot.nodeId) {
            // A committed bot PR holds `committedQueryTab` only BECAUSE the bot query
            // returned it (a bot-authored PR never matches `author:@me`), so that
            // tab's regular query being incomplete must not keep it alive — only
            // the bot query itself can. Its other tabs (e.g. a team review request
            // under For me) still carry forward normally.
            let isCommitted = isCommittedBotPR(snapshot, botAuthors: committedBotAuthors)
            var reasons = snapshot.tabs
                .filter { !(isCommitted && $0 == committedQueryTab) }
                .compactMap { incompleteTabs[$0] }
            if let reason = incompleteCommittedQuery, isCommitted {
                reasons.append(reason)
            }
            if let reason = incompleteDiscovery, isDiscoveredPR(snapshot) {
                reasons.append(reason)
            }
            guard !reasons.isEmpty else { continue }
            // `degradedPage` wins so the attribution is deterministic regardless of
            // the iteration order of `snapshot.tabs` (a Set).
            let reason: CarryForwardReason = reasons.contains(.degradedPage) ? .degradedPage : .noData
            result.append(snapshot)
            carriedReasons[snapshot.nodeId] = reason
        }
        return CarryForwardResult(snapshots: result, carriedReasons: carriedReasons)
    }

    /// Removes carried-forward PRs that GitHub now reports as MERGED or CLOSED.
    ///
    /// Carrying forward is blind by design — it re-adds the last known snapshot of
    /// anything an incomplete fetch didn't return. But the open-PR searches can
    /// never return a PR that has since finished, so if the same query stays
    /// incomplete poll after poll (a bot query that only ever got its half-size
    /// retry through did exactly that), a merged PR is carried forever, frozen as
    /// "open". `states` comes from one cheap `GitHubClient.fetchPRStates` lookup of
    /// the carried ids; a finished PR is dropped exactly as a complete poll would
    /// have dropped it. Dropping fires nothing — `PRDiffEngine` only diffs PRs that
    /// are present.
    ///
    /// Only CARRIED PRs are vetted: a fetched PR is fresh by definition. A carried
    /// PR with no reported state (lookup failed, node unresolvable) is KEPT —
    /// unknown is not finished, and dropping it would re-notify it as `.newPR`
    /// once it reappears.
    nonisolated static func droppingFinished(
        _ result: CarryForwardResult,
        states: [String: String]
    ) -> (result: CarryForwardResult, dropped: Int) {
        let finished = Set(result.carriedReasons.keys.filter { id in
            states[id].map { $0.uppercased() != "OPEN" } ?? false
        })
        guard !finished.isEmpty else { return (result, 0) }
        var pruned = result
        pruned.snapshots.removeAll { finished.contains($0.nodeId) }
        for id in finished { pruned.carriedReasons[id] = nil }
        return (pruned, finished.count)
    }

    // MARK: - Committed-PR bot query (pure)

    /// Canonical form of a bot entered in Settings: `dash0-dev[bot]`, `app/dash0-dev`
    /// and `Dash0-Dev` all become `dash0-dev` — the bare login GraphQL returns for a
    /// Bot author, and the name the `author:app/<name>` search qualifier wants.
    nonisolated static func normalizedBotAuthor(_ raw: String) -> String {
        var login = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if login.hasPrefix("app/") { login.removeFirst("app/".count) }
        return InboxMuteEngine.normalizeBotLogin(login)
    }

    /// The search that discovers PRs bots opened on your behalf, or nil when no bot
    /// is configured. GitHub ORs repeated `author:` qualifiers. `sort:updated-desc`
    /// keeps the most recently active PRs inside the single 100-result page when a
    /// busy bot has more open PRs than that. The results still contain OTHER
    /// people's bot PRs — the poller keeps only `viewerIsCommitter` ones.
    nonisolated static func committedPRQuery(botAuthors: [String]) -> String? {
        let names = botAuthors.map(normalizedBotAuthor).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        var seen = Set<String>()
        let qualifiers = names.filter { seen.insert($0).inserted }.map { "author:app/\($0)" }
        return (["is:open", "is:pr", "sort:updated-desc"] + qualifiers).joined(separator: " ")
    }

    /// The bounded `poll.query_type` telemetry label for the committed-PR bot query.
    nonisolated static let committedQueryTelemetryType = "committed"

    /// The newly added bots whose PRs this poll is SEEDING, not announcing: the
    /// first complete bot-query poll after a bot is listed returns PRs that are
    /// new to the store but long open, so `.newPR` for them is suppressed (no
    /// banner, no unread dot). `known == nil` (first poll since launch) seeds
    /// nothing — those PRs are already in the persisted store.
    nonisolated static func seedingBots(current: Set<String>, known: Set<String>?) -> Set<String> {
        guard let known else { return [] }
        return current.subtracting(known)
    }

    /// Whether a snapshot is one the committed-PR bot query returns (and keeps):
    /// authored by a configured bot AND carrying the viewer's commits.
    /// `botAuthors` holds `normalizedBotAuthor` forms.
    nonisolated static func isCommittedBotPR(_ snapshot: PRSnapshot, botAuthors: Set<String>) -> Bool {
        snapshot.viewerIsCommitter && botAuthors.contains(normalizedBotAuthor(snapshot.author))
    }

    // MARK: - Focus-author discovery (pure)

    /// GitHub rejects search queries over 256 characters; stay under it.
    nonisolated private static let discoveryQueryBudget = 220

    /// `author:` qualifier for a focus entry: bots need the `app/` form.
    nonisolated private static func discoveryQualifier(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isBot = trimmed.lowercased().hasPrefix("app/") || trimmed.lowercased().hasSuffix("[bot]")
        return isBot ? "author:app/\(normalizedBotAuthor(trimmed))" : "author:\(trimmed.lowercased())"
    }

    /// The searches that discover open PRs by each org's Review Focus authors
    /// (excluding your own). One query per org, split into several when the author
    /// list would overflow GitHub's query length. Empty when no org has authors.
    nonisolated static func focusDiscoveryQueries(focusByOrg: [String: OrgFocusConfig]) -> [String] {
        var queries: [String] = []
        for org in focusByOrg.keys.sorted() {
            var seen = Set<String>()
            let qualifiers = (focusByOrg[org]?.authors ?? [])
                .compactMap(discoveryQualifier)
                .filter { seen.insert($0).inserted }
            guard !qualifiers.isEmpty else { continue }
            let head = "is:open is:pr sort:updated-desc -author:@me org:\(org.lowercased())"
            var current = head
            for q in qualifiers {
                if current != head, current.count + 1 + q.count > discoveryQueryBudget {
                    queries.append(current)
                    current = head
                }
                current += " " + q
            }
            queries.append(current)
        }
        return queries
    }

    // MARK: Team rosters

    nonisolated static let rosterTTL: TimeInterval = 24 * 3600
    nonisolated static let rosterErrorRetry: TimeInterval = 3600

    nonisolated static func rosterKey(org: String, slug: String) -> String {
        "\(org.lowercased())/\(slug.lowercased())"
    }

    /// Whether a team's cached roster should be re-fetched: never fetched, a day
    /// old, or failed more than an hour ago.
    nonisolated static func rosterNeedsRefresh(_ roster: TeamRoster?, now: Date) -> Bool {
        guard let roster else { return true }
        let ttl = roster.error == nil ? rosterTTL : rosterErrorRetry
        return now.timeIntervalSince(roster.attemptedAt) >= ttl
    }

    /// The focus config with every configured team's cached members folded into its
    /// authors, so discovery and "is this a focus-author PR" see one author list.
    nonisolated static func effectiveFocus(
        _ focusByOrg: [String: OrgFocusConfig],
        rosters: [String: TeamRoster]
    ) -> [String: OrgFocusConfig] {
        var result = focusByOrg
        for (org, config) in focusByOrg {
            var authors = config.authors
            for slug in config.teams {
                authors += rosters[rosterKey(org: org, slug: slug)]?.members ?? []
            }
            result[org] = OrgFocusConfig(authors: authors, teams: config.teams)
        }
        return result
    }

    /// Re-fetches the members of every team in Review Focus whose cache is stale
    /// (or all of them when `force`), and drops cache entries for teams no longer
    /// configured. A failed fetch keeps the last good members and records the error.
    func refreshTeamRosters(token: String, force: Bool, org only: String? = nil) async {
        let now = Date()
        var rosters = settings.teamRosters
        var wanted = Set<String>()
        for (org, config) in settings.reviewFocusByOrg {
            for slug in config.teams {
                let key = Self.rosterKey(org: org, slug: slug)
                wanted.insert(key)
                if let only, only.lowercased() != org.lowercased() { continue }
                guard force || Self.rosterNeedsRefresh(rosters[key], now: now) else { continue }
                do {
                    let members = try await client.fetchTeamMembers(org: org, slug: slug, token: token)
                    rosters[key] = TeamRoster(members: members, fetchedAt: now, attemptedAt: now, error: nil)
                } catch {
                    var previous = rosters[key] ?? TeamRoster(members: [], fetchedAt: nil, attemptedAt: now, error: nil)
                    previous.attemptedAt = now
                    if case GitHubAPIError.unknown(let code) = error {
                        previous.error = (code == 403 || code == 404)
                            ? "HTTP \(code) — token needs read:org, or the team slug is wrong"
                            : "HTTP \(code)"
                    } else {
                        previous.error = error.localizedDescription
                    }
                    rosters[key] = previous
                }
            }
        }
        rosters = rosters.filter { wanted.contains($0.key) }
        if rosters != settings.teamRosters { settings.teamRosters = rosters }
    }

    /// A discovered PR that should stay silent: no review request on you, or only a
    /// team request for a team that is not one of your configured focus teams (a
    /// CODEOWNERS team on someone else's PR must not make discovery noisy).
    nonisolated static func isQuietDiscovered(
        _ snapshot: PRSnapshot,
        effective: [String: OrgFocusConfig],
        configured: [String: OrgFocusConfig],
        myLogin: String,
        committedPlacement: CommittedPRPlacement
    ) -> Bool {
        guard isFocusDiscoveredPR(snapshot, focusByOrg: effective, myLogin: myLogin,
                                  committedPlacement: committedPlacement) else { return false }
        switch snapshot.reviewRequestSource(myLogin: myLogin) {
        case .direct: return false
        case .none:   return true
        case .team:
            let org = snapshot.org.lowercased()
            let teams = configured.first { $0.key.lowercased() == org }?.value.teams ?? []
            return !snapshot.requestedTeams.contains { requested in
                teams.contains { $0.lowercased() == requested.lowercased() }
            }
        }
    }

    /// The bounded `poll.query_type` telemetry label for the focus-author search.
    nonisolated static let discoveryQueryTelemetryType = "focus_authors"

    /// Whether a snapshot is one the focus-author search returns: its author is in
    /// its own org's focus authors. Drives by-source carry-forward and banner
    /// suppression, like `isCommittedBotPR`.
    nonisolated static func isFocusDiscoveredPR(
        _ snapshot: PRSnapshot,
        focusByOrg: [String: OrgFocusConfig],
        myLogin: String = "",
        committedPlacement: CommittedPRPlacement = .yourPRs
    ) -> Bool {
        // Your own work is never "discovered": you authored it (a team roster
        // includes you) or committed to it (a focus author can be a bot).
        if snapshot.isViewersWork(myLogin: myLogin, committedPlacement: committedPlacement) { return false }
        guard let focus = InboxMuteEngine.focusConfig(
            for: snapshot.org, in: InboxMuteConfig(
                mutePatterns: [], muteBotAuthors: false, botAllowList: [],
                focusByOrg: focusByOrg, muteLabels: [], myLogin: ""
            )
        ) else { return false }
        let author = InboxMuteEngine.normalizeBotLogin(snapshot.author)
        return focus.authors.contains { InboxMuteEngine.normalizeBotLogin($0) == author }
    }

    // MARK: - Single poll

    /// One full cycle: the PR fetch, then (when wired) the issue fetch. Issues run after
    /// the PRs so an early return inside the PR poll never starves them, and a failure in
    /// one never blocks the other.
    /// - Parameter forced: a manual Refresh — run the Done searches whatever their
    ///   last-run time.
    private func poll(token: String, forced: Bool = false) async {
        // A rate limit is being waited out: skip the whole cycle (PRs, issues, Done,
        // previews) rather than send requests `GitHubClient` would refuse anyway. This
        // also keeps the Refresh button instant — the old handler slept the limit's
        // full duration inside the poll, so a manual refresh hung for minutes.
        if let hit = RateLimitMonitor.shared.blockedHit(for: RateLimitMonitor.pollResource) {
            statusMessage = "Rate limited — resumes \(RateLimitClassifier.clockLabel(hit.resetAt))"
            return
        }
        // The Done searches are display-only and change slowly: run them every
        // `PollPacing.secondaryInterval`, not every poll. Issues stay on every poll —
        // they fire assigned/mentioned notifications. The decision is a PARAMETER, never
        // instance state: a forced refresh can overlap the loop's poll across awaits.
        let runDone = PollPacing.secondaryDue(lastRun: lastDoneAt, now: Date(), forced: forced)
        APIBudget.shared.beginPoll()
        defer { APIBudget.shared.endPoll() }
        await pollPRs(token: token, runDone: runDone)
        if let issueStore {
            await issueStore.poll(client: client, token: token)
        }
    }

    private func pollPRs(token: String, runDone: Bool) async {
        let pollStartedAt = Date()
        // Prune expired snoozes on every poll so postponed PRs silently return to
        // their normal group the moment their wake time passes — even while the
        // panel is closed. Render-time filtering already compares to `Date()`; this
        // keeps the persisted map from growing unbounded. Cheap, main-actor, local.
        SnoozeStore(settings: settings).clearExpired()

        // Always poll both tabs so notifications fire regardless of which tab
        // is currently visible. Each query is tagged with the tab that sourced it.
        var queries: [(tab: ReviewTab, query: String, isCommittedQuery: Bool, isDiscoveryQuery: Bool)] = [
            (.created, settings.searchQueryAuthor, false, false),
            (.forMe,   settings.searchQueryReviewer, false, false)
        ].filter { !$0.query.isEmpty }

        // PRs bots opened on your behalf: GitHub search can't select "has my
        // commits", so fetch the configured bots' open PRs and keep only yours.
        // Always tagged Created, whatever the placement: the tag must not depend on
        // a setting, or flipping the placement re-tags every such PR into For me and
        // `PRDiffEngine` fires `.readyForReview` for each ("entered For me").
        let committedBotAuthors = Set(settings.committedPRBotAuthors.map(Self.normalizedBotAuthor))
        if let committedQuery = Self.committedPRQuery(botAuthors: settings.committedPRBotAuthors) {
            queries.append((.created, committedQuery, true, false))
        }
        // Review Focus authors as a discovery source (opt-in). Tagged For me so the
        // PRs read as review work; carried forward by SOURCE like the bot query.
        if settings.discoverFocusAuthorPRs {
            await refreshTeamRosters(token: token, force: false)
        }
        let focusByOrg = Self.effectiveFocus(settings.reviewFocusByOrg, rosters: settings.teamRosters)
        let myLoginForDiscovery = settings.githubUsername
        // Heavy (up to 100 full PRs per org) and slow-moving, so it runs on the
        // Done-search cadence (`PollPacing.secondaryInterval`), not every poll; the
        // skipped cycles re-add its last results below.
        let discoverySkipped = settings.discoverFocusAuthorPRs && !runDone
        if settings.discoverFocusAuthorPRs && runDone {
            for query in Self.focusDiscoveryQueries(focusByOrg: focusByOrg) {
                queries.append((.forMe, query, false, true))
            }
        }
        var incompleteDiscovery: CarryForwardReason?
        // Set when the committed query's result is incomplete — carried forward by
        // source, never by tab (see `carryingForward`).
        var incompleteCommittedQuery: CarryForwardReason?
        let committedQueryTab = queries.first(where: \.isCommittedQuery)?.tab

        var allSnapshots: [PRSnapshot] = []

        // Tabs whose fetch did NOT produce a complete result set this cycle:
        //   * no fresh data at all — a 304, or a 5xx that survived the client retry;
        //   * a PARTIAL page — the post-5xx retry succeeded at the reduced page size
        //     (`GitHubClient.searchPageSizeDegraded`), so it returned a SUBSET.
        // `PRStateStore.update` rebuilds its dict from exactly the array it is
        // handed, so anything missing is dropped — these tabs' last known snapshots
        // are carried forward below instead.
        // The reason is kept per tab (not just the fact) so the carry-forward can
        // attribute each rescued PR to what actually caused it.
        var incompleteTabs: [ReviewTab: CarryForwardReason] = [:]

        for (tab, query, isCommittedQuery, isDiscoveryQuery) in queries {
            func markIncomplete(_ reason: CarryForwardReason) {
                if isDiscoveryQuery {
                    // Several discovery queries (one per org) share one flag; the
                    // worse reason wins so a degraded page is never downgraded.
                    if incompleteDiscovery != .degradedPage { incompleteDiscovery = reason }
                } else if isCommittedQuery {
                    incompleteCommittedQuery = reason
                } else {
                    incompleteTabs[tab] = reason
                }
            }
            // Its own label, so the bot search doesn't skew the author series.
            let queryType = isDiscoveryQuery
                ? Self.discoveryQueryTelemetryType
                : (isCommittedQuery ? Self.committedQueryTelemetryType : tab.telemetryQueryType)
            let pollStart = Date()
            TelemetryService.shared.recordPollStarted(queryType: queryType)

            do {
                // The bot query has its own two-step fetch: the single full-field
                // search over every PR a bot opened timed out (see
                // `GitHubClient.searchCommittedPRs`).
                let page: (snapshots: [PRSnapshot], degraded: Bool)
                if isCommittedQuery {
                    page = try await client.searchCommittedPRs(
                        query: query, token: token, tab: tab, telemetryQueryType: queryType
                    )
                } else {
                    let search = try await client.searchPRs(
                        query: query, token: token, tab: tab, telemetryQueryType: queryType
                    )
                    page = (search.snapshots, search.degraded)
                }
                let (snapshots, degraded) = page
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollCompleted(
                    queryType: queryType,
                    resultCount: snapshots.count,
                    duration: duration,
                    etag304: false,
                    degraded: degraded
                )
                // A degraded page succeeded, but at half the page size — it is a
                // SUBSET of this tab, not the tab. Treat it as incomplete so the PRs
                // it cut off are carried forward from the store rather than dropped
                // from the diff baseline: dropping them makes the very next full-size
                // poll re-diff each one as `.newPR`, which re-fires its notification
                // and re-lights its unread dot on a PR the user has already seen.
                if degraded { markIncomplete(.degradedPage) }
                // The bot query returns every PR those bots opened — keep only yours.
                allSnapshots.append(contentsOf: isCommittedQuery
                    ? snapshots.filter(\.viewerIsCommitter)
                    : snapshots)
            } catch GitHubAPIError.notModified {
                // 304 — keep existing state, no notification
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollCompleted(
                    queryType: queryType,
                    resultCount: 0,
                    duration: duration,
                    etag304: true
                )
                markIncomplete(.noData)
                continue
            } catch GitHubAPIError.cancelled {
                // Popover closed mid-request; SwiftUI cancelled the `.task`.
                // Benign — keep prior state/counts and do not surface an error.
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollFailed(queryType: queryType, error: .cancelled, duration: duration)
                return
            } catch is CancellationError {
                // Task cancellation — benign, keep prior state. Still close the poll
                // span: leaving it open makes the NEXT poll end it as "abandoned",
                // which shows up in telemetry as a phantom multi-second poll.
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollFailed(queryType: queryType, error: .cancelled, duration: duration)
                return
            } catch GitHubAPIError.serverError(let code) {
                // Transient GitHub 5xx (500/502/503/504), already retried once at a
                // reduced page size by `GitHubClient.searchPRs`. Keep the last
                // successful data/counts for THIS tab and do NOT surface an error
                // banner — the next scheduled poll retries automatically.
                //
                // `continue`, not `return`: the tabs are independent queries, and the
                // reviewer query is the expensive one that times out. Returning here
                // threw away the author query's snapshots that had already been
                // fetched successfully in this cycle, so one flaky tab stalled the
                // whole panel (no store update, no notifications) until a cycle where
                // both tabs happened to succeed. This tab's own PRs are carried
                // forward unchanged after the loop, so nothing disappears.
                let duration = Date().timeIntervalSince(pollStart)
                // `degraded: true` — reaching this catch means `searchPRs` already
                // spent its reduced-page retry and that attempt failed too, so this
                // poll's duration belongs to the degraded bucket, not the healthy one.
                TelemetryService.shared.recordPollFailed(
                    queryType: queryType,
                    error: .serverError(code),
                    duration: duration,
                    degraded: true
                )
                markIncomplete(.noData)
                continue
            } catch GitHubAPIError.rateLimited(let seconds) {
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollFailed(queryType: queryType, error: .rateLimited(retryAfter: seconds), duration: duration)
                // `GitHubClient` already told `RateLimitMonitor`; the next cycles skip
                // until it lifts (see `poll`). No sleep here — it blocked Refresh.
                let resumes = RateLimitClassifier.clockLabel(Date().addingTimeInterval(TimeInterval(seconds)))
                await MainActor.run { self.statusMessage = "Rate limited — resumes \(resumes)" }
                return
            } catch GitHubAPIError.unauthorized {
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollFailed(queryType: queryType, error: .unauthorized, duration: duration)
                TelemetryService.shared.recordTokenInvalid()
                await MainActor.run { self.statusMessage = "Token invalid — open Settings" }
                stop()
                return
            } catch {
                // Defense in depth: never surface cancellation as a visible error.
                if (error as? URLError)?.code == .cancelled || error is CancellationError {
                    return
                }
                // The committed-PR bot query is optional: its failure must not throw
                // away the regular queries' results already fetched this cycle.
                if isCommittedQuery || isDiscoveryQuery {
                    markIncomplete(.noData)
                    continue
                }
                await MainActor.run { self.statusMessage = "Error: \(error.localizedDescription)" }
                return
            }
        }

        // Discovery didn't run this cycle: keep its last results verbatim. This is not
        // a failed fetch, so it bypasses `carryingForward` — no carried-forward
        // telemetry and no `fetchPRStates` vetting request on every skipped poll.
        if discoverySkipped {
            let have = Set(allSnapshots.map(\.nodeId))
            allSnapshots += store.snapshots.values
                .sorted { $0.nodeId < $1.nodeId }
                .filter {
                    !have.contains($0.nodeId)
                        && Self.isFocusDiscoveredPR($0, focusByOrg: focusByOrg, myLogin: myLoginForDiscovery, committedPlacement: settings.committedPRPlacement)
                }
        }

        // Carry forward the last known snapshots for any tab whose result set was
        // incomplete this cycle, so a failed, unchanged or half-size query never
        // empties — or silently truncates — that tab's list.
        var carryForward = Self.carryingForward(
            fetched: allSnapshots,
            previous: store.snapshots,
            incompleteTabs: incompleteTabs,
            incompleteCommittedQuery: incompleteCommittedQuery,
            committedBotAuthors: committedBotAuthors,
            committedQueryTab: committedQueryTab,
            incompleteDiscovery: incompleteDiscovery,
            isDiscoveredPR: { Self.isFocusDiscoveredPR($0, focusByOrg: focusByOrg, myLogin: myLoginForDiscovery, committedPlacement: settings.committedPRPlacement) }
        )
        // Vet what was just carried: a PR that has since merged or closed can't come
        // back through an open-PR search, so without this it stays carried — frozen
        // as open — for as long as its query keeps coming back incomplete. A failed
        // lookup keeps everything (the pre-vetting behavior); it never blocks a poll.
        if !carryForward.carriedReasons.isEmpty,
           let states = try? await client.fetchPRStates(
               nodeIds: carryForward.carriedReasons.keys.sorted(), token: token
           ) {
            let vetted = Self.droppingFinished(carryForward, states: states)
            carryForward = vetted.result
            TelemetryService.shared.recordCarriedForwardFinishedDropped(count: vetted.dropped)
        }
        allSnapshots = carryForward.snapshots

        // Count what the guard just rescued. Every PR here is one that would
        // otherwise have been dropped from the diff baseline and re-fired as a
        // `.newPR` notification on the next complete poll — so this counter, not the
        // downstream notification count, is where a regression in the guard shows up
        // first.
        for (reason, count) in carryForward.carriedByReason {
            TelemetryService.shared.recordPRsCarriedForward(count: count, reason: reason)
        }

        // De-duplicate by nodeId (same PR can appear in both queries),
        // unioning the tab membership so a PR can belong to both tabs.
        var merged: [String: PRSnapshot] = [:]
        var order: [String] = []
        for snapshot in allSnapshots {
            if var existing = merged[snapshot.nodeId] {
                existing.tabs.formUnion(snapshot.tabs)
                merged[snapshot.nodeId] = existing
            } else {
                merged[snapshot.nodeId] = snapshot
                order.append(snapshot.nodeId)
            }
        }
        var unique = order.compactMap { merged[$0] }

        // Carry forward cached Vercel preview URLs before the diff/persist: a PR's
        // preview only changes when a new commit bumps `updatedAt`, so while
        // `updatedAt` is unchanged we reuse the previously-extracted value and skip
        // the per-PR comment fetch entirely. Fresh/changed PRs stay unenriched here
        // and are fetched by `enrichVercelPreviews` after the store update.
        let previousSnapshots = store.snapshots
        for i in unique.indices {
            if let prev = previousSnapshots[unique[i].nodeId],
               prev.vercelPreviewCheckedAt == unique[i].updatedAt {
                unique[i].vercelPreviewUrl = prev.vercelPreviewUrl
                unique[i].vercelPreviewCheckedAt = prev.vercelPreviewCheckedAt
            }
        }

        let myLogin = settings.githubUsername
        let allTransitions = store.update(
            new: unique,
            myLogin: myLogin,
            notifyOnlyHumanComments: settings.notifyOnlyHumanComments
        )

        // Suppress everything for PRs the user has postponed: postponing
        // permanently mutes a PR, so it fires no banner AND lights up no unread dot
        // — not while snoozed, and not after it wakes. The mute set outlives the
        // snooze window (see `MainlineSettings.notifMutedNodeIds`). The PR still
        // updates in the list via the store snapshot; only attention is silenced.
        let muted = settings.notifMutedNodeIds
        var transitions = muted.isEmpty
            ? allTransitions
            : allTransitions.filter { !muted.contains($0.prNodeId) }

        // Adding a bot must not announce its already-open PRs as new. Suppression
        // runs on EVERY poll while a bot is still seeding — a degraded half page
        // must not announce the half it did get — but only a complete bot query
        // moves the known set, so seeding lasts until one full result has landed.
        let seeding = Self.seedingBots(current: committedBotAuthors, known: knownCommittedBots)
        if !seeding.isEmpty {
            let seeded = Set(unique
                .filter { Self.isCommittedBotPR($0, botAuthors: seeding) }
                .map(\.nodeId))
            transitions.removeAll { transition in
                if case .newPR = transition { return seeded.contains(transition.prNodeId) }
                return false
            }
        }
        if committedQueryTab == nil || incompleteCommittedQuery == nil {
            knownCommittedBots = committedBotAuthors
        }

        // Focus-author discovery is passive: a focus author's PR you were NOT asked
        // to review lists quietly — no banner, no unread dot — so turning the
        // setting on can't announce every open PR on the team. A direct request (or
        // one for a configured focus team) ends the quiet.
        var quietDiscoveredIds = Set<String>()
        var discoveredRequests: [HookEvent] = []
        if settings.discoverFocusAuthorPRs {
            let configured = settings.reviewFocusByOrg
            let placement = settings.committedPRPlacement
            func quiet(_ pr: PRSnapshot) -> Bool {
                Self.isQuietDiscovered(pr, effective: focusByOrg, configured: configured,
                                       myLogin: myLogin, committedPlacement: placement)
            }
            // Discovery already tagged these `.forMe`, so `PRDiffEngine` can't see a
            // review request arrive later as "entering For me". Emit it here.
            for pr in unique where !quiet(pr) {
                guard !muted.contains(pr.nodeId), let old = previousSnapshots[pr.nodeId], quiet(old) else { continue }
                let announced = transitions.contains {
                    if case .readyForReview = $0 { return $0.prNodeId == pr.nodeId }
                    return false
                }
                if !announced {
                    // A team request routes like a first sighting (`.newPR` →
                    // `reviewRequestedTeam`, quiet by default); a direct one is
                    // "review requested from me" (`.readyForReview`).
                    transitions.append(pr.reviewRequestSource(myLogin: myLogin) == .team
                        ? .newPR(pr) : .readyForReview(pr))
                    // Discovery tagged it `.forMe` from the start, so the hook diff can't see the request.
                    discoveredRequests.append(HookEvent(trigger: .reviewRequested, pr: pr))
                }
            }
            let quietIds = Set(unique.filter(quiet).map(\.nodeId))
            quietDiscoveredIds = quietIds
            if !quietIds.isEmpty {
                transitions.removeAll { quietIds.contains($0.prNodeId) }
            }
        }

        notifications.fireTransitions(transitions, settings: settings, myLogin: myLogin)

        // Hooks diff the same before/after arrays, so a PR carried forward verbatim or seen for
        // the first time fires nothing. A postponed PR (permanent mute) fires no hook either.
        let hookEvents = (PRHookEngine.events(previous: previousSnapshots, next: unique, myLogin: myLogin) + discoveredRequests)
            .filter { !muted.contains($0.pr.nodeId) && !quietDiscoveredIds.contains($0.pr.nodeId) }
        // The first poll of a launch only re-bases: changes made while the app was closed are not
        // something to auto-launch an agent for.
        let hooksArmed = hooksHavePolledOnce
        hooksHavePolledOnce = true
        if hooksArmed, !hookEvents.isEmpty {
            NotificationCenter.default.post(name: .mainlineHookEvents, object: nil, userInfo: ["events": hookEvents])
        }

        // EVERY surviving transition marks the PR as unread — `.notify`, `.quiet`
        // AND `.off` alike. This maps the pre-filter array and deliberately
        // discards `fireTransitions`'s return value, so an event's attention level
        // decides whether a BANNER appears, never whether the PR counts as unread.
        // Only the mute filter above removes a PR from this set.
        let allTransitionNodeIds = transitions.map { $0.prNodeId }
        let unreadCandidates = Array(Set(allTransitionNodeIds))
        if !unreadCandidates.isEmpty {
            NotificationCenter.default.post(
                name: .mainlineQuietTransitions,
                object: nil,
                userInfo: ["nodeIds": unreadCandidates]
            )
        }

        statusMessage = "Updated \(Date().formatted(date: .omitted, time: .shortened))"
        lastSyncAt = Date()
        UserDefaults.standard.set(lastSyncAt?.timeIntervalSince1970, forKey: "lastFullSyncAt")
        RateLimitMonitor.shared.clear(ifNoHitSince: pollStartedAt)

        // DISPLAY-ONLY Done fetch — recently merged/closed PRs for both tabs.
        // Runs AFTER the open path so it never blocks notifications, and its errors
        // are all swallowed benignly (the Done section is non-critical). Results
        // are pushed to the caller's separate `donePRs` collection and NEVER go
        // through the diff engine / notifications.
        if runDone {
            await fetchDonePRs(token: token)
            lastDoneAt = Date()
        }

        // Enrich the open set with Vercel preview URLs. Runs LAST so it never blocks
        // notifications or the Done section, and only fetches PRs whose preview
        // wasn't already carried forward above.
        await enrichVercelPreviews(from: unique, token: token)
    }

    /// Fetches and applies Vercel preview URLs for the PRs that weren't carried
    /// forward this poll (new PRs, or PRs whose `updatedAt` changed). Sequential
    /// with small batched applies so indicators appear progressively on first load;
    /// the natural upper bound is the search page size, so no extra cap is needed.
    /// Every error is non-critical: the PR is simply left unchecked and retried on
    /// the next poll. Skipped entirely when the feature is off, or when the user has
    /// cleared BOTH match rules — a domain suffix and a link label are independent
    /// ways to find the URL, so either one alone is enough to keep detecting.
    private func enrichVercelPreviews(from snapshots: [PRSnapshot], token: String) async {
        guard settings.vercelPreviewEnabled else { return }
        let domains = settings.vercelPreviewDomains
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let linkLabels = settings.previewLinkLabels
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !domains.isEmpty || !linkLabels.isEmpty else { return }
        let authors = settings.previewCommentAuthors

        // Only PRs whose preview hasn't been checked at their current `updatedAt`.
        let toFetch = snapshots.filter { $0.vercelPreviewCheckedAt != $0.updatedAt }
        guard !toFetch.isEmpty else { return }

        var pending: [String: (url: String?, checkedAt: String)] = [:]
        for pr in toFetch {
            if Task.isCancelled { break }
            let url: String?
            do {
                url = try await client.fetchPreviewURL(
                    repoFullName: pr.repoFullName,
                    number: pr.number,
                    domains: domains,
                    authors: authors,
                    linkLabels: linkLabels,
                    token: token
                )
            } catch {
                // Non-critical (auth/rate-limit/5xx/decoding/cancellation): leave the
                // PR unchecked so the next poll retries it, and keep going.
                continue
            }
            pending[pr.nodeId] = (url: url, checkedAt: pr.updatedAt)
            if pending.count >= 8 {
                store.applyVercelPreviews(pending)
                pending.removeAll()
            }
        }
        store.applyVercelPreviews(pending)
    }

    /// Fetches the recently-completed (merged/closed) PRs for both tabs, dedupes by
    /// nodeId (unioning tab membership), and hands the result to `onDonePRs`. All
    /// errors — 304, cancellation, transient 5xx, auth, decoding — are handled the
    /// same benign way as the open fetch: they never surface a banner and never
    /// clear a previously-loaded Done set (on error we simply skip the update).
    private func fetchDonePRs(token: String) async {
        guard let onDonePRs else { return }

        let tabs: [ReviewTab] = [.created, .forMe]
        var collected: [PRSnapshot] = []
        var complete = true

        for tab in tabs {
            do {
                let (snapshots, _) = try await client.searchDonePRs(tab: tab, token: token)
                collected.append(contentsOf: snapshots)
            } catch {
                // 304 (notModified), cancellation, transient 5xx, auth, decoding —
                // all non-critical for the display-only Done section. Skip this tab
                // and keep whatever we already have; the next poll retries.
                complete = false
                continue
            }
        }

        // De-duplicate by nodeId (a PR can appear in both tabs), unioning tabs.
        var merged: [String: PRSnapshot] = [:]
        var order: [String] = []
        for snapshot in collected {
            if var existing = merged[snapshot.nodeId] {
                existing.tabs.formUnion(snapshot.tabs)
                merged[snapshot.nodeId] = existing
            } else {
                merged[snapshot.nodeId] = snapshot
                order.append(snapshot.nodeId)
            }
        }
        let unique = order.compactMap { merged[$0] }

        onDonePRs(unique, complete)
    }
}

extension Notification.Name {
    static let mainlineQuietTransitions = Notification.Name("MainlineQuietTransitions")
    static let mainlineHookEvents = Notification.Name("MainlineHookEvents")
    static let mainlineHookCancel = Notification.Name("MainlineHookCancel")
}

// MARK: - Carry-forward self-checks (DEBUG)

#if DEBUG
/// Assertions for `PRPoller.carryingForward`, the pure half of the poll merge.
/// Mirrors `NotificationRoutingChecks` — invoked once at launch so a regression
/// trips an assertion in a debug build without a full XCTest target.
///
/// The case that matters is the third one: a tab that returned a PARTIAL page must
/// not shrink the diff baseline, because every PR dropped from it re-diffs as
/// `.newPR` on the next complete poll.
enum PollCarryForwardChecks {
    private static func pr(
        _ nodeId: String,
        tabs: Set<ReviewTab>,
        author: String = "someone",
        viewerIsCommitter: Bool = false,
        repo: String = "o/r"
    ) -> PRSnapshot {
        PRSnapshot(
            nodeId: nodeId, number: 1, title: "t", htmlUrl: "u", repoFullName: repo,
            isDraft: false, state: "open", ciStatus: .success, reviewState: .none,
            commentCount: 0, updatedAt: "", author: author,
            requestedReviewers: [], requestedTeams: [], tabs: tabs,
            viewerIsCommitter: viewerIsCommitter
        )
    }

    private static func store(_ snapshots: [PRSnapshot]) -> [String: PRSnapshot] {
        Dictionary(uniqueKeysWithValues: snapshots.map { ($0.nodeId, $0) })
    }

    static func run() {
        let a = pr("a", tabs: [.forMe])
        let b = pr("b", tabs: [.forMe])
        let c = pr("c", tabs: [.created])
        let both = pr("both", tabs: [.forMe, .created])

        // Nothing incomplete → the fetched array is returned untouched, so a PR that
        // genuinely left the search result set is still dropped, and nothing is counted.
        let complete = PRPoller.carryingForward(
            fetched: [a], previous: store([a, b]), incompleteTabs: [:]
        )
        assert(complete.snapshots.map(\.nodeId) == ["a"], "complete poll drops PRs that left the set")
        assert(complete.carriedByReason.isEmpty, "complete poll carries nothing forward")

        // A tab that returned nothing (304 / 5xx) keeps its own PRs...
        let noData = PRPoller.carryingForward(
            fetched: [c], previous: store([a, b, c]), incompleteTabs: [.forMe: .noData]
        )
        assert(Set(noData.snapshots.map(\.nodeId)) == ["a", "b", "c"], "empty tab carries its PRs forward")
        assert(noData.carriedByReason == ["no_data": 2], "empty tab counts both rescued PRs")

        // ...and a HALF-SIZE page does too: `a` came back, `b` was cut off by the
        // reduced page size, and dropping `b` here is what re-fires it as `.newPR`.
        let degraded = PRPoller.carryingForward(
            fetched: [a, c], previous: store([a, b, c]), incompleteTabs: [.forMe: .degradedPage]
        )
        assert(Set(degraded.snapshots.map(\.nodeId)) == ["a", "b", "c"], "degraded page carries the cut-off PRs forward")
        assert(degraded.carriedByReason == ["degraded_page": 1], "degraded page counts only the cut-off PR")

        // A carried-forward PR is re-added VERBATIM — a mutated copy would diff to a
        // transition and notify for a PR nothing actually happened to.
        let verbatim = PRPoller.carryingForward(
            fetched: [], previous: store([b]), incompleteTabs: [.forMe: .degradedPage]
        )
        assert(verbatim.snapshots.count == 1 && verbatim.snapshots[0] == b,
               "carried-forward snapshot is unchanged")

        // Another tab's incompleteness never resurrects this tab's PRs.
        let scoped = PRPoller.carryingForward(
            fetched: [c], previous: store([a, b, c]), incompleteTabs: [.created: .noData]
        )
        assert(scoped.snapshots.map(\.nodeId) == ["c"], "carry-forward is scoped to the incomplete tabs")
        assert(scoped.carriedByReason.isEmpty, "nothing rescued means nothing counted")

        // Order is deterministic: fetched first, then carried-forward by nodeId.
        assert(PRPoller.carryingForward(
            fetched: [c], previous: store([b, a, c]), incompleteTabs: [.forMe: .degradedPage]
        ).snapshots.map(\.nodeId) == ["c", "a", "b"], "carry-forward order is deterministic")

        // A PR in BOTH incomplete tabs is counted ONCE, under the more specific
        // reason — otherwise the counter reads as more PRs rescued than exist.
        let mixed = PRPoller.carryingForward(
            fetched: [],
            previous: store([both]),
            incompleteTabs: [.forMe: .degradedPage, .created: .noData]
        )
        assert(mixed.snapshots.map(\.nodeId) == ["both"], "a both-tabs PR is carried once")
        assert(mixed.carriedByReason == ["degraded_page": 1],
               "a both-tabs PR counts once, degraded wins over no_data")

        // MARK: Committed-PR bot query
        assert(PRPoller.seedingBots(current: ["a"], known: nil).isEmpty,
               "first poll since launch seeds nothing (the store is persisted)")
        assert(PRPoller.seedingBots(current: ["a", "b"], known: ["a"]) == ["b"],
               "a newly listed bot is seeded, not announced")
        assert(PRPoller.seedingBots(current: ["a"], known: ["a", "b"]).isEmpty,
               "removing a bot seeds nothing")
        assert(PRPoller.committedPRQuery(botAuthors: []) == nil, "no bots → no extra query")
        assert(PRPoller.committedPRQuery(botAuthors: [" ", ""]) == nil, "blank entries → no extra query")
        assert(PRPoller.committedPRQuery(botAuthors: ["dash0-dev[bot]", "app/Dash0-Dev", "renovate"])
            == "is:open is:pr sort:updated-desc author:app/dash0-dev author:app/renovate",
               "bot entries normalize + dedupe into author:app/ qualifiers")

        let bots: Set<String> = ["dash0-dev"]
        let mine = pr("mine", tabs: [.created], author: "dash0-dev", viewerIsCommitter: true)
        let authored = pr("authored", tabs: [.created], author: "me")
        assert(PRPoller.isCommittedBotPR(mine, botAuthors: bots), "bot PR with my commits is committed-sourced")
        assert(!PRPoller.isCommittedBotPR(
            pr("theirs", tabs: [.created], author: "dash0-dev"), botAuthors: bots),
               "bot PR without my commits is not kept")

        // A 304 on the bot query keeps ITS PRs — and only its PRs: sharing the
        // Created tab must not keep an authored PR that left the author query.
        let committed304 = PRPoller.carryingForward(
            fetched: [], previous: store([mine, authored]), incompleteTabs: [:],
            incompleteCommittedQuery: .noData, committedBotAuthors: bots
        )
        assert(committed304.snapshots.map(\.nodeId) == ["mine"],
               "committed-query carry-forward is scoped to its own PRs, not its tab")
        assert(committed304.carriedByReason == ["no_data": 1], "committed carry-forward is counted")

        // The reverse: the AUTHOR query 304s while the bot query completed without
        // `mine` (it merged). The shared Created tag must not resurrect it.
        let author304 = PRPoller.carryingForward(
            fetched: [], previous: store([mine, authored]), incompleteTabs: [.created: .noData],
            committedBotAuthors: bots, committedQueryTab: .created
        )
        assert(author304.snapshots.map(\.nodeId) == ["authored"],
               "a regular-query 304 never carries a committed bot PR on the shared tab")

        // MARK: Focus-author discovery
        assert(PRPoller.focusDiscoveryQueries(focusByOrg: [:]).isEmpty, "no focus → no discovery query")
        assert(PRPoller.focusDiscoveryQueries(focusByOrg: ["dash0hq": OrgFocusConfig(authors: [], teams: ["ai"])]).isEmpty,
               "teams alone never trigger a search")
        assert(PRPoller.focusDiscoveryQueries(focusByOrg: [
            "Dash0HQ": OrgFocusConfig(authors: ["Alice", "alice", "dash0-dev[bot]"], teams: [])
        ]) == ["is:open is:pr sort:updated-desc -author:@me org:dash0hq author:alice author:app/dash0-dev"],
               "authors dedupe + lowercase, bots use author:app/")
        let many = (0..<40).map { "teammember\($0)" }
        let chunked = PRPoller.focusDiscoveryQueries(focusByOrg: ["o": OrgFocusConfig(authors: many, teams: [])])
        assert(chunked.count > 1 && chunked.allSatisfy { $0.count <= 256 }, "long author lists split under GitHub's 256-char cap")
        let focus = ["dash0hq": OrgFocusConfig(authors: ["jlguerreiro"], teams: [])]
        assert(PRPoller.isFocusDiscoveredPR(
            pr("a", tabs: [.forMe], author: "JLGuerreiro", repo: "dash0hq/dash0"), focusByOrg: focus),
               "focus author match is case-insensitive")
        assert(!PRPoller.isFocusDiscoveredPR(
            pr("b", tabs: [.forMe], author: "jlguerreiro", repo: "other/dash0"), focusByOrg: focus),
               "focus is per org")
        // Team rosters fold into authors; stale/failed cadence; own PRs excluded.
        let rosters = ["dash0hq/ai-growth": TeamRoster(members: ["Bob", "me"], fetchedAt: nil, attemptedAt: Date(), error: nil)]
        let eff = PRPoller.effectiveFocus(
            ["dash0hq": OrgFocusConfig(authors: ["alice"], teams: ["AI-Growth"])], rosters: rosters)
        assert(eff["dash0hq"]?.authors == ["alice", "Bob", "me"], "team members join the focus authors")
        assert(PRPoller.focusDiscoveryQueries(focusByOrg: eff).first?.contains("author:bob") == true,
               "a team-only org still produces a discovery query")
        assert(!PRPoller.isFocusDiscoveredPR(
            pr("m", tabs: [.created], author: "me", repo: "dash0hq/x"), focusByOrg: eff, myLogin: "ME"),
               "your own PR is never discovered, even when you're on the team")
        let t0 = Date()
        assert(PRPoller.rosterNeedsRefresh(nil, now: t0), "never fetched → refresh")
        assert(!PRPoller.rosterNeedsRefresh(
            TeamRoster(members: [], fetchedAt: t0, attemptedAt: t0, error: nil), now: t0.addingTimeInterval(3600)),
               "fresh roster is kept for a day")
        assert(PRPoller.rosterNeedsRefresh(
            TeamRoster(members: [], fetchedAt: t0, attemptedAt: t0, error: nil), now: t0.addingTimeInterval(86_401)),
               "a day-old roster refreshes")
        assert(PRPoller.rosterNeedsRefresh(
            TeamRoster(members: [], fetchedAt: nil, attemptedAt: t0, error: "x"), now: t0.addingTimeInterval(3601)),
               "a failed roster retries hourly")
        // Quiet mode: only a direct request, or one for a configured focus team, ends it.
        func prq(_ teams: [String], _ reviewers: [String]) -> PRSnapshot {
            var p = pr("q", tabs: [.forMe], author: "jlguerreiro", repo: "dash0hq/dash0")
            p.requestedTeams = teams
            p.requestedReviewers = reviewers
            return p
        }
        let cfg = ["dash0hq": OrgFocusConfig(authors: ["jlguerreiro"], teams: ["ai-platform"])]
        func quiet(_ p: PRSnapshot) -> Bool {
            PRPoller.isQuietDiscovered(p, effective: cfg, configured: cfg, myLogin: "me", committedPlacement: .yourPRs)
        }
        assert(quiet(prq([], [])), "no request → quiet")
        assert(!quiet(prq([], ["me"])), "a direct request ends quiet")
        assert(!quiet(prq(["AI-Platform"], [])), "a focus-team request ends quiet (case-insensitive)")
        assert(quiet(prq(["codeowners-team"], [])), "an unrelated team request stays quiet")
        assert(!PRPoller.isFocusDiscoveredPR(
            pr("c", tabs: [.forMe], author: "jlguerreiro", viewerIsCommitter: true, repo: "dash0hq/dash0"),
            focusByOrg: cfg, myLogin: "me", committedPlacement: .yourPRs),
               "a PR you committed to is never discovered")
        let disc = pr("disc", tabs: [.forMe], author: "jlguerreiro")
        let discCarried = PRPoller.carryingForward(
            fetched: [], previous: store([disc]), incompleteTabs: [:],
            incompleteDiscovery: .noData, isDiscoveredPR: { $0.author == "jlguerreiro" }
        )
        assert(discCarried.snapshots.map(\.nodeId) == ["disc"], "an incomplete discovery query keeps its own PRs")

        // MARK: Vetting carried PRs (`droppingFinished`)
        // The stale-merged-PR bug: the bot query only ever got its degraded page
        // through, so every merged bot PR was carried forward forever.
        let merged = pr("merged", tabs: [.created], author: "dash0-dev", viewerIsCommitter: true)
        let closed = pr("closed", tabs: [.created], author: "dash0-dev", viewerIsCommitter: true)
        let fresh = pr("fresh", tabs: [.created], author: "dash0-dev", viewerIsCommitter: true)
        let carried = PRPoller.carryingForward(
            fetched: [fresh], previous: store([fresh, mine, merged, closed]), incompleteTabs: [:],
            incompleteCommittedQuery: .degradedPage, committedBotAuthors: bots
        )
        assert(carried.carriedByReason == ["degraded_page": 3], "precondition: the degraded page carries all three")

        let vetted = PRPoller.droppingFinished(carried, states: [
            "fresh": "MERGED",   // fetched, so never vetted — a fetched PR is fresh by definition
            "mine": "OPEN",
            "merged": "MERGED",
            "closed": "CLOSED",
        ])
        assert(vetted.result.snapshots.map(\.nodeId) == ["fresh", "mine"],
               "a carried PR GitHub reports merged/closed is dropped; open and fetched PRs stay")
        assert(vetted.dropped == 2, "both finished PRs are counted")
        assert(vetted.result.carriedByReason == ["degraded_page": 1],
               "the carried count only covers PRs still carried")

        // Unknown is not finished: a failed or partial state lookup keeps the PR,
        // because dropping it would re-notify it as `.newPR` when it reappears.
        let unknown = PRPoller.droppingFinished(carried, states: ["merged": "MERGED"])
        assert(Set(unknown.result.snapshots.map(\.nodeId)) == ["fresh", "mine", "closed"],
               "a carried PR with no reported state is kept")
        assert(PRPoller.droppingFinished(carried, states: [:]).result == carried,
               "no states → the carry-forward is untouched")
    }
}
#endif
