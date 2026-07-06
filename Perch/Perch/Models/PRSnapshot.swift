import Foundation

// MARK: - Supporting Enums

enum CIStatus: String, Codable, Equatable {
    case unknown
    case pending
    case success
    case failure
    case error
}

enum ReviewState: String, Codable, Equatable {
    case none
    case requested
    case approved
    case changesRequested
}

/// GitHub's aggregate review decision for a PR.
/// Mirrors GraphQL `PullRequest.reviewDecision`.
enum ReviewDecision: String, Codable, Equatable {
    case approved          = "APPROVED"
    case changesRequested  = "CHANGES_REQUESTED"
    case reviewRequired    = "REVIEW_REQUIRED"
}

/// Which Linear-style tab a PR belongs to.
/// A PR can appear in both (e.g. authored a PR you were also asked to review).
enum ReviewTab: String, Codable, Equatable, CaseIterable, Identifiable {
    case forMe    // review-requested / assigned to me
    case created  // authored by me

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forMe:   return "For me"
        case .created: return "Created"
        }
    }
}

/// The six mutually-exclusive buckets a PR is grouped under, in display order.
enum PRState: String, Codable, Equatable, CaseIterable {
    case open       // open, non-draft, no review yet (REVIEW_REQUIRED / null)
    case inReview   // open, non-draft, changes requested / reviews exist but not approved
    case approved   // open, non-draft, APPROVED
    case draft      // open && isDraft
    case merged     // merged
    case closed     // closed && !merged

    /// Section header label.
    var title: String {
        switch self {
        case .open:     return "Open"
        case .inReview: return "In Review"
        case .approved: return "Approved"
        case .draft:    return "Draft"
        case .merged:   return "Merged"
        case .closed:   return "Closed"
        }
    }

    /// Deterministic display order used to sort sections.
    var sortIndex: Int {
        switch self {
        case .open:     return 0
        case .inReview: return 1
        case .approved: return 2
        case .draft:    return 3
        case .merged:   return 4
        case .closed:   return 5
        }
    }
}

// MARK: - PRSnapshot

/// Canonical diff unit — one instance per PR, stored in PRStateStore.
/// All fields are observable so PRDiffEngine can detect any transition.
struct PRSnapshot: Codable, Equatable {
    let nodeId: String              // PR node_id (stable key)
    let number: Int
    let title: String
    let htmlUrl: String
    let repoFullName: String        // "owner/repo"
    var isDraft: Bool
    var state: String               // raw REST state: "open" | "closed"
    var merged: Bool                // GraphQL PullRequest.merged
    var closed: Bool                // GraphQL PullRequest.closed
    var reviewDecision: ReviewDecision?
    var ciStatus: CIStatus
    var reviewState: ReviewState
    var commentCount: Int           // total comment count for new-comment detection
    var updatedAt: String           // ISO 8601
    let author: String              // PR author login
    var requestedReviewers: [String] // logins requested for review
    /// Which tab(s) surfaced this PR. Unioned when the same PR appears in both queries.
    var tabs: Set<ReviewTab>

    init(
        nodeId: String,
        number: Int,
        title: String,
        htmlUrl: String,
        repoFullName: String,
        isDraft: Bool,
        state: String,
        merged: Bool = false,
        closed: Bool = false,
        reviewDecision: ReviewDecision? = nil,
        ciStatus: CIStatus,
        reviewState: ReviewState,
        commentCount: Int,
        updatedAt: String,
        author: String,
        requestedReviewers: [String],
        tabs: Set<ReviewTab> = []
    ) {
        self.nodeId = nodeId
        self.number = number
        self.title = title
        self.htmlUrl = htmlUrl
        self.repoFullName = repoFullName
        self.isDraft = isDraft
        self.state = state
        self.merged = merged
        self.closed = closed
        self.reviewDecision = reviewDecision
        self.ciStatus = ciStatus
        self.reviewState = reviewState
        self.commentCount = commentCount
        self.updatedAt = updatedAt
        self.author = author
        self.requestedReviewers = requestedReviewers
        self.tabs = tabs
    }

    // MARK: - Classification

    /// Classify the PR into one of the six display buckets.
    var classifiedState: PRState {
        if merged { return .merged }
        if closed { return .closed }        // closed && !merged (merged handled above)
        if isDraft { return .draft }        // open && draft
        switch reviewDecision {
        case .approved:         return .approved
        case .changesRequested: return .inReview
        case .reviewRequired, .none:
            // No decision yet. If reviews exist but no formal decision, treat as In Review.
            return reviewState == .changesRequested ? .inReview : .open
        }
    }
}
