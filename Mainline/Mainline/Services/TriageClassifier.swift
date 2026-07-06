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
    static func needsHuman(
        _ pr: PRSnapshot,
        myLogin: String,
        trustTier: TrustTier
    ) -> Bool {
        !triggers(pr, myLogin: myLogin, trustTier: trustTier).isEmpty
    }

    /// Returns the full list of triage triggers that apply to this PR.
    static func triggers(
        _ pr: PRSnapshot,
        myLogin: String,
        trustTier: TrustTier
    ) -> [TriageTrigger] {
        var result: [TriageTrigger] = []

        // CI failure on a known trusted agent's PR (not fresh/unknown authors)
        if (pr.ciStatus == .failure || pr.ciStatus == .error) && trustTier != .probation {
            // Only flag if this is someone else's PR (agent's work)
            if pr.author != myLogin {
                result.append(.failingCIOnTrustedAgent)
            }
        }

        // Merge conflict — GitHub computes this lazily; nil = unknown, treat as clear
        if pr.mergeable == false {
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
