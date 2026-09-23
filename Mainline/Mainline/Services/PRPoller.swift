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

/// The merged snapshot array plus how many PRs the carry-forward rescued, split by
/// reason. The counts feed `TelemetryService.recordPRsCarriedForward`; each PR is
/// counted exactly ONCE, so the total is a true PR count rather than a per-tab tally
/// that double-counts anything sitting in both tabs.
struct CarryForwardResult: Equatable {
    var snapshots: [PRSnapshot]
    var carriedByReason: [String: Int]
}

/// Task-based poll loop. Cancels cleanly via `stop()`.
/// All state writes go through PRStateStore — PRPoller never mutates snapshots directly.
@MainActor
final class PRPoller {
    private let client:       GitHubClient
    private let store:        PRStateStore
    private let notifications: NotificationService
    private let settings:     MainlineSettings

    private var pollingTask: Task<Void, Never>?

    /// Human-readable status for the menu bar.
    @Published private(set) var statusMessage: String = "Not started"

    /// Sink for the DISPLAY-ONLY "Done" set (recently merged/closed PRs), fetched
    /// alongside the open sets each poll but stored SEPARATELY by the caller
    /// (`PRManager.donePRs`). These NEVER pass through `PRStateStore` /
    /// `PRDiffEngine` / notifications, so a merged PR can't fire a "new PR" banner.
    /// Set by `PRManager`; nil = no Done fetch performed.
    var onDonePRs: (([PRSnapshot]) -> Void)?

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
                let interval = Double(self.settings.pollIntervalSeconds)
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
    func pollOnce(token: String) async {
        await poll(token: token)
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
        committedQueryTab: ReviewTab? = nil
    ) -> CarryForwardResult {
        guard !incompleteTabs.isEmpty || incompleteCommittedQuery != nil else {
            return CarryForwardResult(snapshots: fetched, carriedByReason: [:])
        }

        var result = fetched
        var carriedByReason: [String: Int] = [:]
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
            guard !reasons.isEmpty else { continue }
            // `degradedPage` wins so the attribution is deterministic regardless of
            // the iteration order of `snapshot.tabs` (a Set).
            let reason: CarryForwardReason = reasons.contains(.degradedPage) ? .degradedPage : .noData
            result.append(snapshot)
            carriedByReason[reason.rawValue, default: 0] += 1
        }
        return CarryForwardResult(snapshots: result, carriedByReason: carriedByReason)
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

    /// Whether a snapshot is one the committed-PR bot query returns (and keeps):
    /// authored by a configured bot AND carrying the viewer's commits.
    /// `botAuthors` holds `normalizedBotAuthor` forms.
    nonisolated static func isCommittedBotPR(_ snapshot: PRSnapshot, botAuthors: Set<String>) -> Bool {
        snapshot.viewerIsCommitter && botAuthors.contains(normalizedBotAuthor(snapshot.author))
    }

    // MARK: - Single poll

    private func poll(token: String) async {
        // Prune expired snoozes on every poll so postponed PRs silently return to
        // their normal group the moment their wake time passes — even while the
        // panel is closed. Render-time filtering already compares to `Date()`; this
        // keeps the persisted map from growing unbounded. Cheap, main-actor, local.
        SnoozeStore(settings: settings).clearExpired()

        // Always poll both tabs so notifications fire regardless of which tab
        // is currently visible. Each query is tagged with the tab that sourced it.
        var queries: [(tab: ReviewTab, query: String, isCommittedQuery: Bool)] = [
            (.created, settings.searchQueryAuthor, false),
            (.forMe,   settings.searchQueryReviewer, false)
        ].filter { !$0.query.isEmpty }

        // PRs bots opened on your behalf: GitHub search can't select "has my
        // commits", so fetch the configured bots' open PRs and keep only yours.
        // Tagged with the tab its placement implies (yours → Created).
        let committedBotAuthors = Set(settings.committedPRBotAuthors.map(Self.normalizedBotAuthor))
        if let committedQuery = Self.committedPRQuery(botAuthors: settings.committedPRBotAuthors) {
            let tab: ReviewTab = settings.committedPRPlacement == .yourPRs ? .created : .forMe
            queries.append((tab, committedQuery, true))
        }
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

        for (tab, query, isCommittedQuery) in queries {
            func markIncomplete(_ reason: CarryForwardReason) {
                if isCommittedQuery {
                    incompleteCommittedQuery = reason
                } else {
                    incompleteTabs[tab] = reason
                }
            }
            let queryType = tab.telemetryQueryType
            let pollStart = Date()
            TelemetryService.shared.recordPollStarted(queryType: queryType)

            do {
                let (snapshots, _, degraded) = try await client.searchPRs(query: query, token: token, tab: tab)
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
                await MainActor.run { self.statusMessage = "Rate limited — wait \(seconds)s" }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
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
                if isCommittedQuery {
                    markIncomplete(.noData)
                    continue
                }
                await MainActor.run { self.statusMessage = "Error: \(error.localizedDescription)" }
                return
            }
        }

        // Carry forward the last known snapshots for any tab whose result set was
        // incomplete this cycle, so a failed, unchanged or half-size query never
        // empties — or silently truncates — that tab's list.
        let carryForward = Self.carryingForward(
            fetched: allSnapshots,
            previous: store.snapshots,
            incompleteTabs: incompleteTabs,
            incompleteCommittedQuery: incompleteCommittedQuery,
            committedBotAuthors: committedBotAuthors,
            committedQueryTab: committedQueryTab
        )
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
        let transitions = muted.isEmpty
            ? allTransitions
            : allTransitions.filter { !muted.contains($0.prNodeId) }

        notifications.fireTransitions(transitions, settings: settings, myLogin: myLogin)

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

        // DISPLAY-ONLY Done fetch — recently merged/closed PRs for both tabs.
        // Runs AFTER the open path so it never blocks notifications, and its errors
        // are all swallowed benignly (the Done section is non-critical). Results
        // are pushed to the caller's separate `donePRs` collection and NEVER go
        // through the diff engine / notifications.
        await fetchDonePRs(token: token)

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

        for tab in tabs {
            do {
                let (snapshots, _) = try await client.searchDonePRs(tab: tab, token: token)
                collected.append(contentsOf: snapshots)
            } catch {
                // 304 (notModified), cancellation, transient 5xx, auth, decoding —
                // all non-critical for the display-only Done section. Skip this tab
                // and keep whatever we already have; the next poll retries.
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

        onDonePRs(unique)
    }
}

extension Notification.Name {
    static let mainlineQuietTransitions = Notification.Name("MainlineQuietTransitions")
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
        viewerIsCommitter: Bool = false
    ) -> PRSnapshot {
        PRSnapshot(
            nodeId: nodeId, number: 1, title: "t", htmlUrl: "u", repoFullName: "o/r",
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
    }
}
#endif
