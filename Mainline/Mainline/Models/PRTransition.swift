import Foundation

/// Output type of the PRDiffEngine — one value per detected state transition.
enum PRTransition {
    case newPR(PRSnapshot)
    case readyForReview(PRSnapshot)
    case ciStatusChanged(PRSnapshot, from: CIStatus, to: CIStatus)
    case newReviewOrComment(PRSnapshot)

    /// The nodeId of the PR this transition concerns — the single accessor callers
    /// use to correlate a transition with per-PR state (e.g. the notification-mute
    /// set) without re-switching over every case.
    var prNodeId: String {
        switch self {
        case .newPR(let pr), .readyForReview(let pr),
             .ciStatusChanged(let pr, _, _), .newReviewOrComment(let pr):
            return pr.nodeId
        }
    }
}
