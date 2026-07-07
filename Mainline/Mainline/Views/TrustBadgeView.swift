import SwiftUI

// MARK: - TrustBadgeView

/// Compact trust tier badge shown in PR rows.
/// Displays a colored dot with a single-letter tier initial (P/T/A).
struct TrustBadgeView: View {
    let tier: TrustTier

    var body: some View {
        // `.probation` is the uninformative default — the trust ledger starts
        // empty, so every author reports as `.probation` until they earn a
        // verdict history. Rendering a badge for it puts a meaningless red "P" on
        // every row, so only the meaningful tiers (Trusted / Autopilot) render.
        // All call sites benefit without extra guards.
        if tier == .probation {
            EmptyView()
        } else {
            ZStack {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 16, height: 16)
                Text(tier.initial)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Trust tier: \(tier.rawValue)")
        }
    }

    private var badgeColor: Color {
        switch tier {
        case .probation: return Color(nsColor: .systemRed)
        case .trusted:   return Color(nsColor: .systemOrange)
        case .autopilot: return Color(nsColor: .systemGreen)
        }
    }
}
