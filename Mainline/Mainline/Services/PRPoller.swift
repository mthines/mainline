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
        // Always poll both tabs so notifications fire regardless of which tab
        // is currently visible. Each query is tagged with the tab that sourced it.
        let queries: [(tab: ReviewTab, query: String)] = [
            (.created, settings.searchQueryAuthor),
            (.forMe,   settings.searchQueryReviewer)
        ].filter { !$0.query.isEmpty }

        var allSnapshots: [PRSnapshot] = []

        for (tab, query) in queries {
            do {
                let (snapshots, _) = try await client.searchPRs(query: query, token: token, tab: tab)
                allSnapshots.append(contentsOf: snapshots)
            } catch GitHubAPIError.notModified {
                // 304 — keep existing state, no notification
                continue
            } catch GitHubAPIError.cancelled {
                // Popover closed mid-request; SwiftUI cancelled the `.task`.
                // Benign — keep prior state/counts and do not surface an error.
                return
            } catch is CancellationError {
                // Task cancellation — benign, keep prior state.
                return
            } catch GitHubAPIError.serverError {
                // Transient GitHub 5xx (500/502/503/504). Treat like cancellation:
                // keep the last successful data/counts and do NOT surface an error
                // banner. The next scheduled poll retries automatically.
                return
            } catch GitHubAPIError.rateLimited(let seconds) {
                await MainActor.run { self.statusMessage = "Rate limited — wait \(seconds)s" }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                return
            } catch GitHubAPIError.unauthorized {
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
        let transitions = store.update(new: unique, myLogin: myLogin)
        notifications.fireTransitions(transitions, settings: settings, myLogin: myLogin)

        // ALL transitions (notify + quiet) mark the PR as unread
        let allTransitionNodeIds: [String] = transitions.compactMap { transition in
            switch transition {
            case .newPR(let pr), .readyForReview(let pr),
                 .ciStatusChanged(let pr, _, _), .newReviewOrComment(let pr):
                return pr.nodeId
            }
        }
        let unreadCandidates = Array(Set(allTransitionNodeIds))
        if !unreadCandidates.isEmpty {
            NotificationCenter.default.post(
                name: .mainlineQuietTransitions,
                object: nil,
                userInfo: ["nodeIds": unreadCandidates]
            )
        }

        statusMessage = "Updated \(Date().formatted(date: .omitted, time: .shortened))"
    }
}

extension Notification.Name {
    static let mainlineQuietTransitions = Notification.Name("MainlineQuietTransitions")
}
