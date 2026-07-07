import Foundation

// MARK: - TriageTrigger

/// The specific reason a PR has been routed to the "Needs a Human" bucket.
enum TriageTrigger: Equatable {
    case failingCIOnTrustedAgent
    case mergeConflict
    case sensitivePathTouched([String])
    case agentVsAgentThread
    case staleAndBlocking
}

// MARK: - TriageClassifier

/// Pure, stateless predicate engine that determines whether a PR requires
/// human attention. Mirrors the `PRDiffEngine` pure-enum pattern — no I/O.
enum TriageClassifier {

    /// Returns true if the PR needs human intervention for any reason.
    ///
    /// - Parameter includeConflicts: when true, an unmergeable PR (merge
    ///   conflict) also routes into the bucket. Default `false` — conflicts are
    ///   low-urgency and shown as an informational tag only, keeping the bucket
    ///   focused on CI health.
    static func needsHuman(
        _ pr: PRSnapshot,
        myLogin: String,
        trustTier: TrustTier,
        includeConflicts: Bool = false
    ) -> Bool {
        !triggers(pr, myLogin: myLogin, trustTier: trustTier, includeConflicts: includeConflicts).isEmpty
    }

    /// Returns the full list of triage triggers that apply to this PR.
    static func triggers(
        _ pr: PRSnapshot,
        myLogin: String,
        trustTier: TrustTier,
        includeConflicts: Bool = false
    ) -> [TriageTrigger] {
        var result: [TriageTrigger] = []

        // Failing CI is the PRIMARY trigger: any non-draft PR with red CI
        // surfaces, regardless of trust tier or authorship. Red CI must always
        // be visible.
        if pr.classifiedState != .draft && (pr.ciStatus == .failure || pr.ciStatus == .error) {
            result.append(.failingCIOnTrustedAgent)
        }

        // Merge conflict — gated behind an opt-in setting so conflicts don't
        // dominate the bucket. GitHub computes mergeability lazily; nil =
        // unknown, treated as clear.
        if includeConflicts && pr.mergeable == false {
            result.append(.mergeConflict)
        }

        // Sensitive path via branch-name heuristic (branch name is synchronous;
        // full file-list check is async REST and handled separately when available)
        if SensitivePathMatcher.isSensitive(pr.headRefName) {
            result.append(.sensitivePathTouched([pr.headRefName]))
        }

        // Sensitive path via known sensitive paths (populated by REST fetch when available)
        if let paths = pr.sensitivePathFlags, !paths.isEmpty {
            result.append(.sensitivePathTouched(paths))
        }

        // Stale + blocking (approved but not merged for > 3 days)
        if pr.classifiedState == .approved {
            let staleThreshold: TimeInterval = 3 * 24 * 60 * 60
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallback = ISO8601DateFormatter()
            if let updatedDate = formatter.date(from: pr.updatedAt) ?? fallback.date(from: pr.updatedAt) {
                if Date().timeIntervalSince(updatedDate) > staleThreshold {
                    result.append(.staleAndBlocking)
                }
            }
        }

        return result
    }
}
