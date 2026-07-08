import Foundation

/// Single source of truth for all PR state.
/// All writes go through `update(new:)` — the poller never writes state directly.
///
/// State is persisted to disk (Application Support) so the diff baseline survives
/// app relaunches. Without this, `snapshots` started empty every launch and the
/// first poll diffed every open PR as `.newPR` — flooding the user with a banner
/// per PR on every open. With persistence, the first poll after relaunch notifies
/// only for what actually changed since the app was last open ("diff since last
/// time"). On a truly first run (no persisted history yet) the first diff is
/// suppressed entirely, so even the initial launch is quiet.
@MainActor
final class PRStateStore: ObservableObject {
    /// Keyed by PR nodeId.
    @Published private(set) var snapshots: [String: PRSnapshot] = [:]

    /// Whether a persisted snapshot file existed at load time. When false (truly
    /// first run — no history yet), the first `update` diff is suppressed so we
    /// don't flood the user with a "New PR" banner for every currently-open PR.
    private var hadPersistedHistory = false

    /// Set once the first `update` has run this launch, so first-run suppression
    /// only ever applies to the very first diff.
    private var didRunFirstUpdate = false

    // MARK: - Persistence URL

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("com.mainline.github-pr-notifier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pr-snapshots.json")
    }

    // MARK: - Load

    /// Loads the persisted snapshot baseline from disk. On a missing or corrupt
    /// file, keeps the empty dictionary and leaves `hadPersistedHistory` false so
    /// the first diff is suppressed. Must be awaited before the first poll so the
    /// baseline is in place.
    func load() async {
        let url = Self.storageURL
        let loaded: [String: PRSnapshot]? = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? JSONDecoder().decode([String: PRSnapshot].self, from: data)
        }.value

        if let loaded {
            self.snapshots = loaded
            self.hadPersistedHistory = true
        }
        // Missing / unreadable / corrupt → stay empty; hadPersistedHistory stays
        // false → the first diff is suppressed (treated as a first run).
    }

    // MARK: - Update

    /// Replaces the current snapshot set with a new array, runs the diff engine,
    /// persists the new baseline, and returns the detected transitions.
    ///
    /// On the first `update` of a truly-first run (no persisted history), returns
    /// no transitions: the fetched PRs become the silent baseline instead of
    /// firing a banner each. Every later poll diffs normally.
    func update(new: [PRSnapshot], myLogin: String, notifyOnlyHumanComments: Bool = false) -> [PRTransition] {
        let transitions = PRDiffEngine.diff(
            previous: snapshots,
            next: new,
            myLogin: myLogin,
            notifyOnlyHumanComments: notifyOnlyHumanComments
        )

        // Rebuild the dict from the new array
        var updated: [String: PRSnapshot] = [:]
        for pr in new {
            updated[pr.nodeId] = pr
        }
        snapshots = updated
        persist(updated)

        // First run with no persisted baseline: seed silently. Without this, every
        // PR diffs as `.newPR` and the user gets a banner per open PR on first launch.
        let suppress = !hadPersistedHistory && !didRunFirstUpdate
        didRunFirstUpdate = true
        return suppress ? [] : transitions
    }

    /// All currently tracked PRs as a flat array, sorted by updatedAt descending.
    var allPRs: [PRSnapshot] {
        snapshots.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Private persistence

    private func persist(_ snapshot: [String: PRSnapshot]) {
        let url = Self.storageURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
