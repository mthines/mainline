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
                continue
            } catch GitHubAPIError.cancelled {
                // Popover closed mid-request; SwiftUI cancelled the `.task`.
                // Benign — keep prior state/counts and do not surface an error.
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollFailed(queryType: queryType, error: .cancelled, duration: duration)
                return
            } catch is CancellationError {
                // Task cancellation — benign, keep prior state.
                return
            } catch GitHubAPIError.serverError(let code) {
                // Transient GitHub 5xx (500/502/503/504). Treat like cancellation:
                // keep the last successful data/counts and do NOT surface an error
                // banner. The next scheduled poll retries automatically.
                let duration = Date().timeIntervalSince(pollStart)
                TelemetryService.shared.recordPollFailed(queryType: queryType, error: .serverError(code), duration: duration)
                return
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
        let unique = order.compactMap { merged[$0] }

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
