import Foundation

// MARK: - Verdict

/// The outcome of a single PR action recorded in the trust ledger.
enum Verdict: String, Codable {
    case merged
    case reverted
    case changesRequested
}

// MARK: - VerdictRecord

/// One recorded outcome for a specific PR, used to compute a trust score.
struct VerdictRecord: Codable {
    let prNodeId: String
    let author: String
    let verdict: Verdict
    let date: Date
    let linesChanged: Int
    let hadTests: Bool
}

// MARK: - TrustTier

/// Derived tier from an author's cumulative score.
/// - probation: score < 0.5 — new or unreliable author
/// - trusted:   0.5...0.85 — solid track record
/// - autopilot: > 0.85 — highly reliable, eligible for auto-approve
enum TrustTier: String, Codable {
    case probation
    case trusted
    case autopilot

    /// Single-character abbreviation shown in `TrustBadgeView`.
    var initial: String {
        switch self {
        case .probation: return "P"
        case .trusted:   return "T"
        case .autopilot: return "A"
        }
    }
}

// MARK: - AgentTrustRecord

/// Aggregate trust data for a single author login.
struct AgentTrustRecord: Codable {
    let login: String
    var verdicts: [VerdictRecord]

    var tier: TrustTier {
        TrustCalculator.tier(for: login, history: verdicts)
    }
}

// MARK: - AutoApproveRule

/// Criteria for the autopilot auto-approve path.
struct AutoApproveRule: Codable {
    var maxLinesChanged: Int = 50
    var requireTests: Bool = true
    var allowedPaths: [String] = []  // empty = no restriction
}

// MARK: - TrustCalculator

/// Pure, stateless scoring engine for trust tiers.
/// Mirrors `PRDiffEngine` — no I/O, easily testable.
enum TrustCalculator {
    /// Returns the derived tier for an author given their verdict history.
    static func tier(for author: String, history: [VerdictRecord]) -> TrustTier {
        let s = score(history: history)
        if s > 0.85 { return .autopilot }
        if s >= 0.5  { return .trusted }
        return .probation
    }

    /// Computes a 0.0–1.0 reliability score from a verdict history.
    /// - Merged: +1.0 per record
    /// - Reverted: -2.0 per record (heavier penalty)
    /// - ChangesRequested: -0.5 per record
    /// With zero records, defaults to 0.0 (probation until proven).
    static func score(history: [VerdictRecord]) -> Double {
        guard !history.isEmpty else { return 0.0 }

        // Apply recency weighting: more recent records carry more weight.
        let sorted = history.sorted { $0.date < $1.date }
        var weightedSum: Double = 0
        var totalWeight: Double = 0

        for (index, record) in sorted.enumerated() {
            let weight = Double(index + 1)  // newer records have higher index = more weight
            let delta: Double
            switch record.verdict {
            case .merged:           delta = 1.0
            case .reverted:         delta = -2.0
            case .changesRequested: delta = -0.5
            }
            weightedSum += delta * weight
            totalWeight += weight
        }

        // Normalise to [0, 1] range.
        let raw = totalWeight > 0 ? weightedSum / totalWeight : 0.0
        // raw is in [-2, 1]; map to [0, 1]
        let normalised = (raw + 2.0) / 3.0
        return max(0.0, min(1.0, normalised))
    }
}
