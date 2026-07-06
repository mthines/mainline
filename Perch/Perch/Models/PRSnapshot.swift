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
    var state: String               // "open" | "closed"
    var ciStatus: CIStatus
    var reviewState: ReviewState
    var commentCount: Int           // total comment count for new-comment detection
    var updatedAt: String           // ISO 8601
    let author: String              // PR author login
    var requestedReviewers: [String] // logins requested for review
}
