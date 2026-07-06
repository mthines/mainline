import SwiftUI

// MARK: - MenuBarBadge

/// Encodes the three distinct icon states for the menu bar badge.
/// Shape + tint are both used for colorblind safety.
enum MenuBarBadge {
    case allClear                  // hollow circle — nothing needs attention
    case ciRunning(Int)            // amber hourglass — pending CI on user's PRs
    case mergeBlocker(Int)         // red exclamation — failing CI on user's PRs

    var symbolName: String {
        switch self {
        case .allClear:       return "circle"
        case .ciRunning:      return "hourglass.circle"
        case .mergeBlocker:   return "exclamationmark.circle.fill"
        }
    }

    var count: Int? {
        switch self {
        case .allClear:            return nil
        case .ciRunning(let n):    return n
        case .mergeBlocker(let n): return n
        }
    }
}

// MARK: - MenuBarIconView

/// Dynamic menu bar icon label that encodes PR attention state.
/// Replaces the static `systemImage: "arrow.triangle.pull"` in MainlineApp.
///
/// Badge encoding (colorblind-safe — shape + tint):
/// - allClear:     hollow circle, neutral   — 0 PRs need attention
/// - ciRunning:    hourglass amber          — pending CI on user's PRs
/// - mergeBlocker: filled exclamation red   — failing CI / merge conflict
struct MenuBarIconView: View {
    let prs: [PRSnapshot]
    let myLogin: String

    var badge: MenuBarBadge {
        guard !myLogin.isEmpty else { return .allClear }

        var blocker = 0
        var pending = 0

        for pr in prs {
            let isMyPR = pr.author == myLogin
            let reviewRequested = pr.tabs.contains(.forMe) && pr.requestedReviewers.contains(myLogin)

            if isMyPR && (pr.ciStatus == .failure || pr.ciStatus == .error) {
                blocker += 1
            } else if reviewRequested && (pr.ciStatus == .success || pr.ciStatus == .unknown) {
                pending += 1
            } else if (isMyPR || reviewRequested) && pr.ciStatus == .pending {
                pending += 1
            }
        }

        if blocker > 0 { return .mergeBlocker(blocker) }
        if pending > 0 { return .ciRunning(pending) }
        return .allClear
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: badge.symbolName)
                .foregroundStyle(iconColor)
                .symbolRenderingMode(.hierarchical)
            if let count = badge.count {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(iconColor)
            }
        }
    }

    private var iconColor: Color {
        switch badge {
        case .allClear:      return .secondary
        case .ciRunning:     return Color(nsColor: .systemOrange)
        case .mergeBlocker:  return Color(nsColor: .systemRed)
        }
    }
}
