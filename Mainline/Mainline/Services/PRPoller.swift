import Foundation

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

    // MARK: - Single poll

    private func poll(token: String) async {
        // Prune expired snoozes on every poll so postponed PRs silently return to
        // their normal group the moment their wake time passes — even while the
        // panel is closed. Render-time filtering already compares to `Date()`; this
        // keeps the persisted map from growing unbounded. Cheap, main-actor, local.
        SnoozeStore(settings: settings).clearExpired()

        // Always poll both tabs so notifications fire regardless of which tab
        // is currently visible. Each query is tagged with the tab that sourced it.
        let queries: [(tab: ReviewTab, query: String)] = [
            (.created, settings.searchQueryAuthor),
            (.forMe,   settings.searchQueryReviewer)
        ].filter { !$0.query.isEmpty }

        var allSnapshots: [PRSnapshot] = []

        // Tabs whose fetch produced no fresh data this cycle (304, or a 5xx that
        // survived the client-side retry). `PRStateStore.update` rebuilds its dict
        // from exactly the array it is handed, so anything missing is dropped — the
        // stale tabs' last known snapshots are carried forward below instead.
        var staleTabs: Set<ReviewTab> = []

        for (tab, query) in queries {
            let queryType = tab == .created ? "author" : "reviewer"
            let pollStart = Date()
            TelemetryService.shared.recordPollStarted(queryType: queryType)

            do {
                let (snapshots, _) = try await client.searchPRs(query: query, token: token, tab: tab)
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollCompleted(
                    queryType: queryType,
                    resultCount: snapshots.count,
                    duration: duration,
                    etag304: false
                )
                allSnapshots.append(contentsOf: snapshots)
            } catch GitHubAPIError.notModified {
                // 304 — keep existing state, no notification
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollCompleted(
                    queryType: queryType,
                    resultCount: 0,
                    duration: duration,
                    etag304: true
                )
                staleTabs.insert(tab)
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
                TelemetryService.shared.recordPollFailed(queryType: queryType, error: .serverError(code), duration: duration)
                staleTabs.insert(tab)
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
                await MainActor.run { self.statusMessage = "Error: \(error.localizedDescription)" }
                return
            }
        }

        // Carry forward the last known snapshots for any tab that returned no fresh
        // data, so a single failed/unchanged query never empties that tab's list.
        // Only PRs the successful queries did NOT return are re-added, and they are
        // re-added verbatim — an unchanged snapshot diffs to no transition, so this
        // preserves the list without firing a notification.
        if !staleTabs.isEmpty {
            let fetchedIds = Set(allSnapshots.map(\.nodeId))
            for snapshot in store.snapshots.values
            where !fetchedIds.contains(snapshot.nodeId) && !snapshot.tabs.isDisjoint(with: staleTabs) {
                allSnapshots.append(snapshot)
            }
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

        // ALL surviving transitions (notify + quiet) mark the PR as unread
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
