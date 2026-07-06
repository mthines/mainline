import Foundation

/// Pure stateless diff engine.
/// Compares previous and next PR snapshots and returns the list of transitions.
enum PRDiffEngine {
    /// Compute transitions between two PR snapshots.
    /// - Parameters:
    ///   - previous: Last known state keyed by PR nodeId.
    ///   - next: Newly fetched PRs.
    ///   - myLogin: The authenticated user's GitHub login, used to detect
    ///              review-requested transitions.
    /// - Returns: All detected transitions (zero or more per PR).
    static func diff(
        previous: [String: PRSnapshot],
        next: [PRSnapshot],
        myLogin: String
    ) -> [PRTransition] {
        var transitions: [PRTransition] = []

        for pr in next {
            guard let old = previous[pr.nodeId] else {
                // New PR — not seen before
                transitions.append(.newPR(pr))
                continue
            }

            // Draft → Ready for Review
            if old.isDraft && !pr.isDraft {
                transitions.append(.readyForReview(pr))
            }

            // Review requested from me (new reviewer addition)
            if !myLogin.isEmpty,
               !old.requestedReviewers.contains(myLogin),
               pr.requestedReviewers.contains(myLogin) {
                transitions.append(.readyForReview(pr))
            }

            // CI status changed
            if old.ciStatus != pr.ciStatus {
                transitions.append(.ciStatusChanged(pr, from: old.ciStatus, to: pr.ciStatus))
            }

            // New review or comment
            if pr.commentCount > old.commentCount {
                transitions.append(.newReviewOrComment(pr))
            }
        }

        return transitions
    }
}
