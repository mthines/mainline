import Foundation

/// Owns GitHub issue state: the fetch, the diff baseline, notifications and unread.
///
/// Issues are fetched with up to two searches:
///   1. `involves:@me` — everything that concerns the viewer; repos at Off are dropped client-side.
///   2. only when some repo/org is at "All issues": every open issue in those repos.
/// An incomplete fetch carries the previous issues forward (see `IssueDiffEngine.carryingForward`)
/// so nothing re-notifies. State is persisted so the baseline survives relaunches, and the very
/// first run seeds silently, exactly like `PRStateStore`.
@MainActor
final class IssueStore: ObservableObject {
    /// Every issue currently followed (any watch level except Off), most recently updated first.
    @Published private(set) var issues: [IssueSnapshot] = []

    private var baseline: [String: IssueSnapshot] = [:]
    private var hadPersistedHistory = false
    private var didRunFirstUpdate = false
    /// Lowercased repos that were Off at the last poll. Their issues never reach the baseline,
    /// so a repo switched back on is seeded for one poll instead of re-announcing everything.
    private var offRepos: Set<String> = []

    private let settings: MainlineSettings
    private let notifications: NotificationService

    /// Targets per second-query: keeps the search string well inside GitHub's limits.
    private static let targetsPerQuery = 10

    init(settings: MainlineSettings = .shared, notifications: NotificationService) {
        self.settings = settings
        self.notifications = notifications
    }

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.mainline.github-pr-notifier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("issue-snapshots.json")
    }

    /// Loads the persisted baseline. Must be awaited before the first poll.
    func load() async {
        let url = Self.storageURL
        let loaded: [String: IssueSnapshot]? = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([String: IssueSnapshot].self, from: data)
        }.value
        if let loaded {
            baseline = loaded
            issues = Self.sorted(Array(loaded.values))
            hadPersistedHistory = true
        }
    }

    private func persist(_ snapshots: [String: IssueSnapshot]) {
        let url = Self.storageURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshots) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func sorted(_ list: [IssueSnapshot]) -> [IssueSnapshot] {
        list.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Queries

    static let involvesQuery = "is:open is:issue involves:@me sort:updated-desc"

    /// The "All issues" queries: one search per chunk of `org:` / `repo:` qualifiers.
    static func allIssuesQueries(orgs: [String], repos: [String]) -> [String] {
        let targets = orgs.map { "org:\($0)" } + repos.map { "repo:\($0)" }
        guard !targets.isEmpty else { return [] }
        return stride(from: 0, to: targets.count, by: targetsPerQuery).map { start in
            let chunk = targets[start..<min(start + targetsPerQuery, targets.count)]
            return "is:open is:issue \(chunk.joined(separator: " ")) sort:updated-desc"
        }
    }

    // MARK: - Poll

    func poll(client: GitHubClient, token: String) async {
        let myLogin = settings.githubUsername
        guard !myLogin.isEmpty else { return }

        // `incomplete`: carry previous issues forward. `failed`: a fetch failed or came back
        // partial, which (unlike a cap-only truncation) must not end first-run seeding.
        var incomplete = false
        var failed = false
        var involved: [IssueSnapshot] = []
        var broad: [IssueSnapshot] = []

        do {
            let r = try await client.searchIssues(query: Self.involvesQuery, token: token, myLogin: myLogin)
            involved = r.issues
            incomplete = incomplete || r.incomplete
            failed = failed || (r.incomplete && !r.truncated)
        } catch {
            incomplete = true
            failed = true
        }

        let targets = settings.issueAllTargets
        for query in Self.allIssuesQueries(orgs: targets.orgs, repos: targets.repos) {
            do {
                let r = try await client.searchIssues(query: query, token: token, myLogin: myLogin)
                broad.append(contentsOf: r.issues)
                incomplete = incomplete || r.incomplete
                failed = failed || (r.incomplete && !r.truncated)
            } catch {
                incomplete = true
                failed = true
            }
        }

        // Merge: an issue from the broad search alone is kept only where the repo is at All issues.
        var merged: [String: IssueSnapshot] = [:]
        for issue in involved where settings.issueWatchLevel(forRepo: issue.repoFullName) != .off {
            merged[issue.nodeId] = issue
        }
        for issue in broad where merged[issue.nodeId] == nil
            && settings.issueWatchLevel(forRepo: issue.repoFullName) == .allIssues {
            merged[issue.nodeId] = issue
        }

        let carry = IssueDiffEngine.carryingForward(fetched: Array(merged.values), previous: baseline,
                                                    incomplete: incomplete)
        var carriedIssues = carry.issues
        var carriedCount = carry.carried
        if carry.carried > 0 {
            // Vet what was carried blind: an issue closed since it was last seen must not
            // linger, since an `is:open` search can never return it to clear it.
            let carriedIds = carry.issues.map(\.nodeId).filter { merged[$0] == nil }
            if let states = try? await client.fetchIssueStates(nodeIds: carriedIds, token: token) {
                let closed = Set(carriedIds.filter { states[$0] == "CLOSED" })
                carriedIssues.removeAll { closed.contains($0.nodeId) }
                carriedCount -= closed.count
            }
        }
        let next = carriedIssues.filter { settings.issueWatchLevel(forRepo: $0.repoFullName) != .off }

        let seedRepos = offRepos.filter { settings.issueWatchLevel(forRepo: $0) != .off }
        // A failed fetch may have missed a re-enabled repo's issues: keep it seeding until a poll succeeds.
        offRepos = offRepos.union((involved + broad).map { $0.repoFullName.lowercased() })
            .filter { settings.issueWatchLevel(forRepo: $0) == .off || (failed && seedRepos.contains($0)) }

        let transitions = IssueDiffEngine.diff(
            previous: baseline, next: next, myLogin: myLogin,
            watchLevel: { [settings] in settings.issueWatchLevel(forRepo: $0) },
            seedRepos: seedRepos, now: Date())

        var updated: [String: IssueSnapshot] = [:]
        for issue in next { updated[issue.nodeId] = issue }
        baseline = updated
        issues = Self.sorted(next)

        // First run seeds silently. Seeding finishes only on a poll with no failed or partial
        // fetch: such a first fetch must not end it (or be persisted as the baseline), or the
        // issues it missed would all notify as new on the next poll. A search cut short only
        // by the page cap still seeds, or a user past the cap would never finish seeding.
        let seeding = !hadPersistedHistory && !didRunFirstUpdate
        if seeding && failed {
            pruneUnread()
            TelemetryService.shared.recordIssuePoll(observed: next.count, carriedForward: carriedCount)
            return
        }
        didRunFirstUpdate = true
        persist(updated)
        if !seeding {
            notifications.fireIssueTransitions(transitions, settings: settings)
            markUnread(transitions.filter { settings.level(for: $0.event) != .off }.map { $0.issue.nodeId })
        }
        pruneUnread()

        TelemetryService.shared.recordIssuePoll(observed: next.count, carriedForward: carriedCount)
    }

    // MARK: - Unread / mute (one set serves the Issues tab and the Inbox)

    /// Issue ids that are unread AND still visible (not muted, still followed).
    var unreadIds: Set<String> {
        let muted = Set(settings.mutedIssueIds)
        let live = Set(issues.map(\.nodeId))
        let archived = Set(issues.filter { isArchived($0) }.map(\.nodeId))
        return Set(settings.unreadIssueIds).intersection(live).subtracting(muted).subtracting(archived)
    }

    // MARK: - Archive

    /// An issue is archived while it has had no activity since it was archived.
    func isArchived(_ issue: IssueSnapshot) -> Bool {
        guard let at = settings.archivedIssues[issue.nodeId] else { return false }
        return issue.updatedAt.timeIntervalSince1970 <= at
    }

    /// Followed issues that are not archived.
    var active: [IssueSnapshot] { issues.filter { !isArchived($0) } }

    /// Archived issues, most recently updated first.
    var archived: [IssueSnapshot] { issues.filter { isArchived($0) } }

    /// Hides the issue until it has new activity, and counts it as seen.
    func archive(_ issue: IssueSnapshot) {
        settings.archivedIssues[issue.nodeId] = issue.updatedAt.timeIntervalSince1970
        settings.unreadIssueIds.removeAll { $0 == issue.nodeId }
        objectWillChange.send()
    }

    func unarchive(_ nodeId: String) {
        guard settings.archivedIssues[nodeId] != nil else { return }
        settings.archivedIssues[nodeId] = nil
        objectWillChange.send()
    }

    /// Forgets archive entries for issues that are no longer followed (closed, or repo Off).
    private func pruneArchived() {
        let live = Set(issues.map(\.nodeId))
        let kept = settings.archivedIssues.filter { live.contains($0.key) }
        if kept.count != settings.archivedIssues.count { settings.archivedIssues = kept }
    }

    private func markUnread(_ ids: [String]) {
        let muted = Set(settings.mutedIssueIds)
        var set = Set(settings.unreadIssueIds)
        for id in ids where !muted.contains(id) { set.insert(id) }
        if set != Set(settings.unreadIssueIds) { settings.unreadIssueIds = Array(set).sorted() }
    }

    private func pruneUnread() {
        let live = Set(issues.map(\.nodeId))
        let kept = settings.unreadIssueIds.filter { live.contains($0) }
        if kept.count != settings.unreadIssueIds.count { settings.unreadIssueIds = kept }
        pruneArchived()
    }

    /// An issue is seen when it is opened.
    func markSeen(_ nodeId: String) {
        guard settings.unreadIssueIds.contains(nodeId) else { return }
        settings.unreadIssueIds.removeAll { $0 == nodeId }
        objectWillChange.send()
    }

    func isUnread(_ nodeId: String) -> Bool { unreadIds.contains(nodeId) }

    func toggleMute(_ nodeId: String) {
        if settings.mutedIssueIds.contains(nodeId) {
            settings.mutedIssueIds.removeAll { $0 == nodeId }
        } else {
            settings.mutedIssueIds.append(nodeId)
        }
        objectWillChange.send()
    }

    func isMuted(_ nodeId: String) -> Bool { settings.mutedIssueIds.contains(nodeId) }

    /// Re-applies watch-level changes immediately, without waiting for the next poll.
    func refilter() {
        let kept = issues.filter { settings.issueWatchLevel(forRepo: $0.repoFullName) != .off }
        if kept.count != issues.count {
            issues = kept
            baseline = baseline.filter { entry in kept.contains { $0.nodeId == entry.key } }
            persist(baseline)
        }
    }
}
