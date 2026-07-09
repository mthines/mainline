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

/// Why a PR appears in the "For me" set, given the authenticated user's login.
/// `review-requested:@me` matches when the user is requested directly OR when a
/// team they belong to is requested — this distinguishes the two.
enum ReviewRequestSource: String, Codable, Equatable {
    case direct   // the user's own login is a requested reviewer
    case team     // only a team the user belongs to is requested
    case none     // not review-requested (e.g. authored / assigned another way)
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

// MARK: - ActionGroup

/// Actionability grouping for the browse list — answers "does this PR still need
/// me?" rather than raw review state. This is the primary section grouping for the
/// deck; `PRState` is retained only for the trailing Merged/Closed sections and
/// for ordering/legacy helpers.
///
/// The three open, non-draft buckets are mutually exclusive and evaluated
/// first-match-wins in `PRSnapshot.actionGroup`:
///   - `.needsAttention` — CI failing OR changes requested OR unresolved threads.
///     Explicitly does NOT include merge conflicts (they happen constantly and
///     aren't an attention driver).
///   - `.readyToMerge` — approved && mergeable && CI green.
///   - `.waiting` — everything else open (awaiting review, green, approved-but-
///     not-mergeable, etc.). Nothing needed from the user right now.
/// Plus the terminal buckets: `.draft` (only used when `splitDrafts` is on),
/// `.merged`, `.closed`.
enum ActionGroup: String, Codable, Equatable, CaseIterable {
    case needsAttention
    case readyToMerge
    case waiting
    case draft
    case merged
    case closed
    /// PRs the user postponed (snoozed) and that have not yet woken. Membership is
    /// "snoozed & not expired", INDEPENDENT of actionability — a PR is placed here
    /// by `TriageDeckView` regardless of what `actionGroup(splitDrafts:)` would
    /// otherwise return, because the snooze exclusion has already removed it from
    /// the active view. Always rendered last and collapsed by default.
    case postponed
    /// Recently completed PRs (merged OR closed-not-merged). DISPLAY-ONLY and
    /// LOWEST priority: populated from a separate, bounded fetch that never routes
    /// through the diff engine / notifications, so a merged PR can never fire a
    /// "new PR" banner. Always rendered LAST (below Postponed) and collapsed by
    /// default. `.merged` / `.closed` above are legacy buckets retained for the
    /// `PRState`-based ordering helpers; the browse deck folds both into `.done`.
    case done

    /// Section header label.
    var title: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .readyToMerge:   return "Ready to merge"
        case .waiting:        return "Waiting"
        case .draft:          return "Draft"
        case .merged:         return "Merged"
        case .closed:         return "Closed"
        case .postponed:      return "Postponed"
        case .done:           return "Done"
        }
    }

    /// Deterministic display order used to sort sections.
    var sortIndex: Int {
        switch self {
        case .needsAttention: return 0
        case .readyToMerge:   return 1
        case .waiting:        return 2
        case .draft:          return 3
        case .merged:         return 4
        case .closed:         return 5
        case .postponed:      return 6
        case .done:           return 7
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
    var reviewCount: Int            // total review count for new-review detection
    /// Whether the most recent comment was authored by a bot/app. Used to filter
    /// out bot-only comment activity from the "new review or comment" notification.
    /// false when there are no comments.
    var lastCommentIsBot: Bool
    /// Whether the most recent review was authored by a bot/app. false when none.
    var lastReviewIsBot: Bool
    var updatedAt: String           // ISO 8601
    let author: String              // PR author login
    var requestedReviewers: [String] // logins requested for review (User reviewers)
    /// Team slugs (or names) requested for review. A team request is how a PR can
    /// enter the "For me" set without the user's own login being requested.
    var requestedTeams: [String]
    /// Which tab(s) surfaced this PR. Unioned when the same PR appears in both queries.
    var tabs: Set<ReviewTab>

    // MARK: - Triage Cockpit fields (Layer A/C/B)

    /// Whether the PR has merge conflicts. nil = GitHub hasn't computed yet (treat as no conflict).
    var mergeable: Bool?

    /// The head branch name (e.g. "feat/my-feature"). Used for sensitive-branch heuristics.
    var headRefName: String

    /// Lines added in this PR (from GraphQL additions field).
    var linesAdded: Int

    /// Lines deleted in this PR (from GraphQL deletions field).
    var linesDeleted: Int

    /// Sensitive file paths populated lazily by REST `/files` fetch.
    /// nil = not yet fetched; [] = fetched but none sensitive.
    var sensitivePathFlags: [String]?

    /// Number of unresolved review threads (open conversations) on this PR,
    /// sampled from GraphQL `reviewThreads(first: 20)`. > 0 means someone left a
    /// comment/conversation that hasn't been resolved yet — a signal the PR still
    /// needs the author. Distinct from `commentCount` (which counts issue-level
    /// comments and never resolves).
    var unresolvedThreadCount: Int

    // MARK: - Repository merge capabilities

    /// Whether the PR's repository allows merge-commit merges (`allow_merge_commit`).
    /// Default true (optimistic) when the repo capability wasn't fetched.
    var mergeCommitAllowed: Bool

    /// Whether the PR's repository allows squash merges (`allow_squash_merge`).
    var squashMergeAllowed: Bool

    /// Whether the PR's repository allows rebase merges (`allow_rebase_merge`).
    var rebaseMergeAllowed: Bool

    // MARK: - Vercel preview deployment

    /// The Vercel preview deployment URL for this PR, extracted lazily from the
    /// `vercel[bot]` PR comment. nil = no preview detected (or not yet checked).
    /// Drives the row "Preview" indicator and the `P` open-preview verb.
    var vercelPreviewUrl: String?

    /// The `updatedAt` value at which the Vercel preview was last checked. Used as
    /// a cache key by the poller: while a PR's `updatedAt` is unchanged the cached
    /// `vercelPreviewUrl` is carried forward (no extra comment fetch); a new commit
    /// bumps `updatedAt`, which re-triggers the check. nil = never checked.
    var vercelPreviewCheckedAt: String?

    /// Total lines changed in this PR.
    var totalLines: Int { linesAdded + linesDeleted }

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
        reviewCount: Int = 0,
        lastCommentIsBot: Bool = false,
        lastReviewIsBot: Bool = false,
        updatedAt: String,
        author: String,
        requestedReviewers: [String],
        requestedTeams: [String] = [],
        tabs: Set<ReviewTab> = [],
        mergeable: Bool? = nil,
        headRefName: String = "",
        linesAdded: Int = 0,
        linesDeleted: Int = 0,
        sensitivePathFlags: [String]? = nil,
        unresolvedThreadCount: Int = 0,
        mergeCommitAllowed: Bool = true,
        squashMergeAllowed: Bool = true,
        rebaseMergeAllowed: Bool = true,
        vercelPreviewUrl: String? = nil,
        vercelPreviewCheckedAt: String? = nil
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
        self.reviewCount = reviewCount
        self.lastCommentIsBot = lastCommentIsBot
        self.lastReviewIsBot = lastReviewIsBot
        self.updatedAt = updatedAt
        self.author = author
        self.requestedReviewers = requestedReviewers
        self.requestedTeams = requestedTeams
        self.tabs = tabs
        self.mergeable = mergeable
        self.headRefName = headRefName
        self.linesAdded = linesAdded
        self.linesDeleted = linesDeleted
        self.sensitivePathFlags = sensitivePathFlags
        self.unresolvedThreadCount = unresolvedThreadCount
        self.mergeCommitAllowed = mergeCommitAllowed
        self.squashMergeAllowed = squashMergeAllowed
        self.rebaseMergeAllowed = rebaseMergeAllowed
        self.vercelPreviewUrl = vercelPreviewUrl
        self.vercelPreviewCheckedAt = vercelPreviewCheckedAt
    }

    // MARK: - Bot detection

    /// Whether a comment/review author is a bot or GitHub App. GitHub returns
    /// `__typename == "Bot"` for app/bot authors; app committers also carry a
    /// login ending in `[bot]` (e.g. "dependabot[bot]", "coderabbitai[bot]").
    /// Pure — safe to call from the diff engine and snapshot mapping.
    static func isBot(typename: String?, login: String?) -> Bool {
        if typename == "Bot" { return true }
        if let login, login.lowercased().hasSuffix("[bot]") { return true }
        return false
    }

    // MARK: - Canonical ordering

    /// The single shared comparator used everywhere PRs are listed.
    ///
    /// Primary key: `classifiedState.sortIndex` ascending — Open(0) / InReview(1) /
    /// Approved(2) rank above Draft(3), which ranks above Merged(4) / Closed(5).
    /// This guarantees drafts never appear above non-draft open PRs.
    /// Secondary key: `updatedAt` descending (most recently updated first).
    static func triageOrder(_ lhs: PRSnapshot, _ rhs: PRSnapshot) -> Bool {
        let li = lhs.classifiedState.sortIndex
        let ri = rhs.classifiedState.sortIndex
        if li != ri { return li < ri }
        return lhs.updatedAt > rhs.updatedAt
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

    /// Classify the PR into a display bucket while IGNORING `isDraft` — same
    /// branch logic as `classifiedState`, minus the draft short-circuit. Used for
    /// mixed grouping so a shown draft lands in its real state group (Open,
    /// Approved, etc.) rather than a separate Draft section. Does NOT replace
    /// `classifiedState`, which other code (needs-human, triageOrder) still uses.
    var underlyingState: PRState {
        if merged { return .merged }
        if closed { return .closed }        // closed && !merged (merged handled above)
        switch reviewDecision {
        case .approved:         return .approved
        case .changesRequested: return .inReview
        case .reviewRequired, .none:
            // No decision yet. If reviews exist but no formal decision, treat as In Review.
            return reviewState == .changesRequested ? .inReview : .open
        }
    }

    /// Whether the PR is eligible for a one-click inline Merge: approved, cleanly
    /// mergeable, green CI, and open (non-draft, not merged/closed). Gates the
    /// inline Merge button on PR rows. The button still routes through the same
    /// write-action confirm path (`performAction(.merge)`); this only decides
    /// visibility.
    var readyToMerge: Bool {
        reviewDecision == .approved
            && mergeable == true
            && ciStatus == .success
            && !isDraft
            && !merged
            && !closed
    }

    /// Whether an OPEN, non-draft PR still needs the user's attention:
    /// failing/erroring CI, changes formally requested, OR at least one unresolved
    /// review thread (a pending/open conversation). Deliberately does NOT consider
    /// `mergeable == false` — merge conflicts happen constantly and aren't an
    /// attention driver. This is the single source of truth shared by the list's
    /// "Needs attention" group and the "Needs a Human" bucket.
    var needsAttention: Bool {
        guard !merged, !closed, !isDraft else { return false }
        if ciStatus == .failure || ciStatus == .error { return true }
        if reviewDecision == .changesRequested { return true }
        if unresolvedThreadCount > 0 { return true }
        return false
    }

    /// The actionability section this PR belongs to (first match wins).
    ///
    /// - Parameter splitDrafts: when true, an open draft is routed to its own
    ///   `.draft` group; when false, an open draft is placed in the actionability
    ///   group implied by its non-draft signal (so it mixes in, distinguished only
    ///   by the Draft badge + dimming).
    func actionGroup(splitDrafts: Bool) -> ActionGroup {
        if merged { return .merged }
        if closed { return .closed }
        if splitDrafts && isDraft { return .draft }

        // For an open PR (draft or not) evaluate the actionability signal. Draft
        // short-circuits are already handled above, and `needsAttention` /
        // `readyToMerge` both guard on `!isDraft`; to classify a *shown* draft by
        // its underlying signal we evaluate the same predicates ignoring draft.
        if ciStatus == .failure || ciStatus == .error
            || reviewDecision == .changesRequested
            || unresolvedThreadCount > 0 {
            return .needsAttention
        }
        if reviewDecision == .approved && mergeable == true && ciStatus == .success {
            return .readyToMerge
        }
        return .waiting
    }

    /// Why this PR is in the "For me" set, from the point of view of `myLogin`.
    /// `.direct` when the user is personally a requested reviewer; `.team` when
    /// only a team the user belongs to is requested (the PR was pulled in by a
    /// team request); `.none` otherwise.
    func reviewRequestSource(myLogin: String) -> ReviewRequestSource {
        if !myLogin.isEmpty && requestedReviewers.contains(myLogin) {
            return .direct
        }
        if !requestedTeams.isEmpty {
            return .team
        }
        return .none
    }
}
