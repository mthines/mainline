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

    // MARK: - Services (internal for Settings access)

    let store:          PRStateStore
    let notifications:  NotificationService
    let client:         GitHubClient
    private let poller: PRPoller
    let settings:       MainlineSettings
    let trustLedger:    TrustLedgerStore
    let snoozeStore:    SnoozeStore

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Triage Cockpit computed properties

    /// PRs that need human attention based on TriageClassifier.
    var needsHumanPRs: [PRSnapshot] {
        let myLogin = settings.githubUsername
        return prs.filter { pr in
            let tier = trustLedger.tier(for: pr.author)
            return TriageClassifier.needsHuman(pr, myLogin: myLogin, trustTier: tier)
        }
    }

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

    /// Count of PRs that have been "handled" (not in needs-human bucket).
    var handledCount: Int {
        prs.count - needsHumanPRs.count
    }

    // MARK: - Init

    init(settings: MainlineSettings = .shared) {
        self.settings      = settings
        self.store         = PRStateStore()
        self.notifications = NotificationService()
        self.client        = GitHubClient(settings: settings)
        self.trustLedger   = TrustLedgerStore()
        self.snoozeStore   = SnoozeStore(settings: settings)
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
    }

    // MARK: - Token lifecycle

    func start() async {
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
