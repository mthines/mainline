import Foundation

/// Task-based poll loop. Cancels cleanly via `stop()`.
/// All state writes go through PRStateStore — PRPoller never mutates snapshots directly.
@MainActor
final class PRPoller {
    private let client:       GitHubClient
    private let store:        PRStateStore
    private let notifications: NotificationService
    private let settings:     PerchSettings

    private var pollingTask: Task<Void, Never>?

    /// Human-readable status for the menu bar.
    @Published private(set) var statusMessage: String = "Not started"

    init(
        client:        GitHubClient,
        store:         PRStateStore,
        notifications: NotificationService,
        settings:      PerchSettings = .shared
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

    // MARK: - Single poll

    private func poll(token: String) async {
        let queries = [
            settings.searchQueryAuthor,
            settings.searchQueryReviewer
        ].filter { !$0.isEmpty }

        var allSnapshots: [PRSnapshot] = []

        for query in queries {
            do {
                let (snapshots, _) = try await client.searchPRs(query: query, token: token)
                allSnapshots.append(contentsOf: snapshots)
            } catch GitHubAPIError.notModified {
                // 304 — keep existing state, no notification
                continue
            } catch GitHubAPIError.rateLimited(let seconds) {
                await MainActor.run { self.statusMessage = "Rate limited — wait \(seconds)s" }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                return
            } catch GitHubAPIError.unauthorized {
                await MainActor.run { self.statusMessage = "Token invalid — open Settings" }
                stop()
                return
            } catch {
                await MainActor.run { self.statusMessage = "Error: \(error.localizedDescription)" }
                return
            }
        }

        // De-duplicate by nodeId (same PR can appear in both queries)
        var seen = Set<String>()
        let unique = allSnapshots.filter { seen.insert($0.nodeId).inserted }

        let myLogin = settings.githubUsername
        let transitions = store.update(new: unique, myLogin: myLogin)
        notifications.fireTransitions(transitions, settings: settings)

        statusMessage = "Updated \(Date().formatted(date: .omitted, time: .shortened))"
    }
}
