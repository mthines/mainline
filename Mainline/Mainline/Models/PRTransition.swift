import Foundation

/// Output type of the PRDiffEngine — one value per detected state transition.
enum PRTransition {
    case newPR(PRSnapshot)
    case readyForReview(PRSnapshot)
    case ciStatusChanged(PRSnapshot, from: CIStatus, to: CIStatus)
    case newReviewOrComment(PRSnapshot)
}
