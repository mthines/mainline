import Foundation

// MARK: - AttentionLevel

/// The interruption level for a PR event.
enum AttentionLevel: String, Codable, CaseIterable {
    case notify  // banner + sound + badge update + adds to unread
    case quiet   // badge/unread update only — no banner, no sound
    case off     // no action at all
}

// MARK: - PREvent

/// All PR event types that can generate attention.
enum PREvent: String, Codable, CaseIterable {
    case newPRByMe           // new PR opened by me (authored)
    case reviewRequested     // DIRECT review requested from me (my login)
    case reviewRequestedTeam // review requested from a team I belong to
    case ciFailedOnMyPR      // CI failed on my PR
    case changesRequested    // reviewer requested changes on my PR
    case newReviewOrComment  // new review or comment needing response
    case readyForReview      // PR transitioned from draft to ready
    case prMerged            // PR was merged
    case prClosed            // PR was closed (not merged)
    case ciPassedOnMyPR      // CI turned green on my PR
    case autopilotApproved   // autopilot auto-approved a PR
    case draftCreated        // new draft PR created

    /// Human-readable label for Settings UI.
    var displayName: String {
        switch self {
        case .newPRByMe:          return "New PR opened by me"
        case .reviewRequested:    return "Review requested from me"
        case .reviewRequestedTeam: return "Team review requested"
        case .ciFailedOnMyPR:     return "CI failed on my PR"
        case .changesRequested:   return "Changes requested on my PR"
        case .newReviewOrComment: return "New review or comment"
        case .readyForReview:     return "PR ready for review"
        case .prMerged:           return "PR merged"
        case .prClosed:           return "PR closed"
        case .ciPassedOnMyPR:     return "CI passed on my PR"
        case .autopilotApproved:  return "Autopilot auto-approved"
        case .draftCreated:       return "Draft PR created"
        }
    }
}

// MARK: - Default attention policy (attention-respectful defaults)

extension PREvent {
    /// The default attention level — baked in to be attention-respectful.
    static let defaults: [PREvent: AttentionLevel] = [
        .newPRByMe:          .notify,
        .reviewRequested:    .notify,   // DIRECT request — actionable
        .reviewRequestedTeam: .quiet,   // team pulled it in — lower noise
        .ciFailedOnMyPR:     .notify,
        .changesRequested:   .notify,
        .newReviewOrComment: .notify,
        .readyForReview:     .notify,
        .prMerged:           .quiet,   // good news / terminal — no focus steal
        .prClosed:           .quiet,   // terminal state
        .ciPassedOnMyPR:     .quiet,   // good news — silent update
        .autopilotApproved:  .quiet,   // informational only
        .draftCreated:       .quiet,   // not actionable yet
    ]
}
