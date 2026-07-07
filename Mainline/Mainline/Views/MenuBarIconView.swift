import SwiftUI

// MARK: - MenuBarBadge

/// Encodes the menu-bar badge state, driven by the user-configured metric.
/// Shape + tint are both used for colorblind safety.
///
/// - neutral:   secondary tint — informational counts (e.g. total open)
/// - attention: amber          — items that want a look (needs-a-human, reviews, unread)
/// - blocker:   red            — hard blockers (failing CI)
///
/// A count of 0 always renders as the "all clear" hollow circle regardless of
/// severity, so an empty badge never draws a red/amber dot.
enum MenuBarBadge {
    case neutral(Int)
    case attention(Int)
    case blocker(Int)

    /// The raw count this badge represents.
    var rawCount: Int {
        switch self {
        case .neutral(let n), .attention(let n), .blocker(let n): return n
        }
    }

    /// Whether there is anything to show.
    private var isClear: Bool { rawCount == 0 }

    var symbolName: String {
        guard !isClear else { return "circle" }
        switch self {
        case .neutral:   return "circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .blocker:   return "exclamationmark.triangle.fill"
        }
    }

    /// The number to draw beside the icon, or nil when clear.
    var count: Int? {
        isClear ? nil : rawCount
    }
}

// MARK: - MenuBarIconView

/// Dynamic menu bar icon label that encodes the configured PR metric.
///
/// Badge encoding (colorblind-safe — shape + tint):
/// - clear:     hollow circle, neutral   — 0 items for the chosen metric
/// - neutral:   filled circle, neutral   — informational count (total open)
/// - attention: exclamation circle amber — needs-a-human / reviews / unread
/// - blocker:   exclamation triangle red — failing CI
struct MenuBarIconView: View {
    let badge: MenuBarBadge

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
        guard badge.count != nil else { return .secondary }
        switch badge {
        case .neutral:   return .secondary
        case .attention: return Color(nsColor: .systemOrange)
        case .blocker:   return Color(nsColor: .systemRed)
        }
    }
}
