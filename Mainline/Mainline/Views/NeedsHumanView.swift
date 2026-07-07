import SwiftUI

// MARK: - NeedsHumanView

/// Displays the "Needs a Human" derived bucket at the top of the panel.
/// Shows PR rows for each triage trigger, then collapses the rest to
/// "N handled by agents".
struct NeedsHumanView: View {
    let prs: [PRSnapshot]
    let myLogin: String
    @ObservedObject var trustLedger: TrustLedgerStore

    // MARK: - Derived data

    private var needsHumanPRs: [PRSnapshot] {
        prs.filter { pr in
            let tier = trustLedger.tier(for: pr.author)
            return TriageClassifier.needsHuman(pr, myLogin: myLogin, trustTier: tier)
        }
        .sorted(by: PRSnapshot.triageOrder)
    }

    private var handledCount: Int {
        prs.count - needsHumanPRs.count
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !needsHumanPRs.isEmpty {
                sectionHeader
                ForEach(needsHumanPRs, id: \.nodeId) { pr in
                    needsHumanRow(pr)
                    Divider().padding(.leading, 36)
                }
            }

            if handledCount > 0 {
                handledSummaryRow
            }
        }
    }

    // MARK: - Section header

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .font(.caption)
            Text("Needs a Human")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text("\(needsHumanPRs.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - PR row

    private func needsHumanRow(_ pr: PRSnapshot) -> some View {
        Button {
            if let url = URL(string: pr.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            let trustTier: TrustTier = trustLedger.tier(for: pr.author)
            HStack(alignment: .top, spacing: 8) {
                triggerIcon(for: pr)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text("\(pr.repoFullName) #\(pr.number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TrustBadgeView(tier: trustTier)
                        triggerLabels(for: pr)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func triggerIcon(for pr: PRSnapshot) -> some View {
        let tier = trustLedger.tier(for: pr.author)
        let triggers = TriageClassifier.triggers(pr, myLogin: myLogin, trustTier: tier)
        if triggers.contains(.mergeConflict) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Color(nsColor: .systemRed))
                .accessibilityLabel("Merge conflict")
        } else if triggers.contains(.failingCIOnTrustedAgent) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
                .accessibilityLabel("Failing CI")
        } else {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityLabel("Needs attention")
        }
    }

    @ViewBuilder
    private func triggerLabels(for pr: PRSnapshot) -> some View {
        let tier = trustLedger.tier(for: pr.author)
        let triggers = TriageClassifier.triggers(pr, myLogin: myLogin, trustTier: tier)
        HStack(spacing: 2) {
            ForEach(Array(triggers.enumerated()), id: \.offset) { _, trigger in
                triggerTag(trigger)
            }
        }
    }

    @ViewBuilder
    private func triggerTag(_ trigger: TriageTrigger) -> some View {
        switch trigger {
        case .mergeConflict:
            Text("conflict")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(nsColor: .systemRed).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(Color(nsColor: .systemRed))
        case .failingCIOnTrustedAgent:
            Text("CI fail")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(nsColor: .systemRed).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(Color(nsColor: .systemRed))
        case .sensitivePathTouched:
            Text("sensitive")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(nsColor: .systemOrange).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(Color(nsColor: .systemOrange))
        case .staleAndBlocking:
            Text("stale")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(nsColor: .systemYellow).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(Color(nsColor: .systemYellow))
        case .agentVsAgentThread:
            Text("agent thread")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(nsColor: .systemPurple).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(Color(nsColor: .systemPurple))
        }
    }

    // MARK: - Handled summary

    private var handledSummaryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
                .frame(width: 20, height: 20)
            Text("\(handledCount) handled by agents")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
