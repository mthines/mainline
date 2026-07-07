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
    ///   - notifyOnlyHumanComments: when true, the `newReviewOrComment`
    ///     transition is emitted ONLY when the increase is human-sourced —
    ///     bot-only comment/review activity is ignored. When false, any
    ///     comment/review count increase emits the transition (legacy behavior).
    ///     This affects NOTIFICATIONS only; the caller still updates unread/badge
    ///     state from whatever transitions are (or aren't) emitted per its own
    ///     rules.
    /// - Returns: All detected transitions (zero or more per PR).
    static func diff(
        previous: [String: PRSnapshot],
        next: [PRSnapshot],
        myLogin: String,
        notifyOnlyHumanComments: Bool = false
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

            // Review newly requested from me: the PR entered the "For me" tab
            // (surfaced by the review-requested:@me query) this poll.
            if !old.tabs.contains(.forMe), pr.tabs.contains(.forMe) {
                transitions.append(.readyForReview(pr))
            }

            // CI status changed
            if old.ciStatus != pr.ciStatus {
                transitions.append(.ciStatusChanged(pr, from: old.ciStatus, to: pr.ciStatus))
            }

            // New review or comment. When `notifyOnlyHumanComments` is on, only
            // emit when the increase is human-sourced (the latest comment/review
            // that drove the increase is not a bot); otherwise emit on any
            // comment or review count increase.
            let newComment = pr.commentCount > old.commentCount
            let newReview  = pr.reviewCount > old.reviewCount
            if newComment || newReview {
                let humanSourced =
                    (newComment && !pr.lastCommentIsBot) ||
                    (newReview  && !pr.lastReviewIsBot)
                if !notifyOnlyHumanComments || humanSourced {
                    transitions.append(.newReviewOrComment(pr))
                }
            }
        }

        return transitions
    }
}
