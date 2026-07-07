import SwiftUI

// MARK: - NeedsHumanView

/// Displays the "Needs a Human" derived bucket at the top of the panel.
/// Shows PR rows for each triage trigger, then collapses the rest to
/// "N handled by agents".
struct NeedsHumanView: View {
    /// The tab-agnostic "needs a human" set, computed once on `PRManager`
    /// (scope + drafts + conflicts applied). Passing it in — rather than
    /// recomputing from a tab-scoped list — guarantees this bucket's header
    /// count equals the menu-bar badge.
    let needsHumanPRs: [PRSnapshot]
    /// Count of the scope+draft-filtered population that is NOT in the bucket.
    let handledCount: Int
    let myLogin: String
    /// Whether merge conflicts count toward the bucket. Sourced from settings.
    let includeConflicts: Bool
    /// Max height for the expanded (scrolling) rows region. Bounds the section so
    /// a large bucket can never push the tabs/footer off screen.
    let maxExpandedHeight: CGFloat
    @ObservedObject var trustLedger: TrustLedgerStore

    /// Whether the bucket is expanded into a bounded ScrollView. Owned by
    /// `MenuBarView` and passed down as a Binding so the panel's height math can
    /// react to expansion (collapsed → the whole budget goes to the browse list;
    /// expanded → the needs-human list gets a real, scrolling height). Collapsed
    /// by default so the section never blocks the browse list below it.
    @Binding var expanded: Bool

    // MARK: - Derived data

    /// Bucket rows in display order: CI-failure rows first, then canonical
    /// triage order. `needsHumanPRs` is already filtered upstream.
    private var sortedNeedsHuman: [PRSnapshot] {
        needsHumanPRs.sorted { lhs, rhs in
            let lhsCI = (lhs.ciStatus == .failure || lhs.ciStatus == .error)
            let rhsCI = (rhs.ciStatus == .failure || rhs.ciStatus == .error)
            if lhsCI != rhsCI { return lhsCI }
            return PRSnapshot.triageOrder(lhs, rhs)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sortedNeedsHuman.isEmpty {
                sectionHeader
                // Collapsed by default so a noisy bucket (e.g. dependabot chores
                // with red CI) never blocks the browse list. Tap the header to
                // reveal the bounded, scrolling rows.
                if expanded {
                    bucketRows
                }
            }

            if handledCount > 0 {
                handledSummaryRow
            }
        }
    }

    /// The rows region — shown only when expanded. Every row lives inside a
    /// ScrollView bounded to `maxExpandedHeight` so the section can never grow
    /// unbounded.
    private var bucketRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sortedNeedsHuman, id: \.nodeId) { pr in
                    needsHumanRow(pr)
                    Divider().padding(.leading, 36)
                }
            }
        }
        .frame(maxHeight: maxExpandedHeight)
    }

    // MARK: - Section header (tappable disclosure)

    /// The header doubles as the collapse/expand control. Collapsed, it is the
    /// only thing this section renders — a compact one-line summary that stays
    /// out of the way. It reads "Needs a Human · N".
    private var sectionHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
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
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, expanded ? 2 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide the Needs-a-Human list" : "Show \(needsHumanPRs.count) PRs that need a human")
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
                        ReviewSourceBadge(pr: pr, myLogin: myLogin)
                        FeedbackBadge(pr: pr)
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
        let triggers = TriageClassifier.triggers(pr, myLogin: myLogin, trustTier: tier, includeConflicts: includeConflicts)
        // CI failure is the primary trigger — show it before conflict.
        if triggers.contains(.failingCIOnTrustedAgent) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
                .accessibilityLabel("Failing CI")
        } else if triggers.contains(.mergeConflict) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Color(nsColor: .systemRed))
                .accessibilityLabel("Merge conflict")
        } else {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityLabel("Needs attention")
        }
    }

    /// Triggers to render as row tags. Always includes an informational
    /// `conflict` tag when the PR is unmergeable, even if conflicts are not
    /// routing PRs into the bucket (includeConflicts == false).
    private func displayTriggers(for pr: PRSnapshot) -> [TriageTrigger] {
        let tier = trustLedger.tier(for: pr.author)
        var triggers = TriageClassifier.triggers(pr, myLogin: myLogin, trustTier: tier, includeConflicts: includeConflicts)
        if pr.mergeable == false && !triggers.contains(.mergeConflict) {
            triggers.append(.mergeConflict)
        }
        return triggers
    }

    @ViewBuilder
    private func triggerLabels(for pr: PRSnapshot) -> some View {
        let triggers = displayTriggers(for: pr)
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
