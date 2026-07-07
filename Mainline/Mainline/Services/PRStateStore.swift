import Foundation

/// Single source of truth for all PR state.
/// All writes go through `update(new:)` — the poller never writes state directly.
@MainActor
final class PRStateStore: ObservableObject {
    /// Keyed by PR nodeId.
    @Published private(set) var snapshots: [String: PRSnapshot] = [:]

    /// Replaces the current snapshot set with a new array, runs the diff engine,
    /// and returns the detected transitions.
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

        return transitions
    }

    /// All currently tracked PRs as a flat array, sorted by updatedAt descending.
    var allPRs: [PRSnapshot] {
        snapshots.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}
