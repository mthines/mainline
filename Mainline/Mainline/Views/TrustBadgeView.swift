import SwiftUI

// MARK: - TrustBadgeView

/// Compact trust tier badge shown in PR rows.
/// Displays a colored dot with a single-letter tier initial (P/T/A).
struct TrustBadgeView: View {
    let tier: TrustTier

    var body: some View {
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

    private var badgeColor: Color {
        switch tier {
        case .probation: return Color(nsColor: .systemRed)
        case .trusted:   return Color(nsColor: .systemOrange)
        case .autopilot: return Color(nsColor: .systemGreen)
        }
    }
}
