import SwiftUI

// MARK: - NeedsHumanHeaderView

/// The always-pinned "Needs a Human" chrome: the tappable disclosure header and
/// the "N handled by agents" summary. Rendered OUTSIDE the shared scroll region
/// (as fixed chrome) by `MenuBarView`; the bucket ROWS live in the scroll region
/// (`NeedsHumanRowsView`). Splitting header from rows lets a single scroll region
/// own all scrolling — the two independently-fixed nested ScrollViews that caused
/// the expand crash are gone.
struct NeedsHumanHeaderView: View {
    /// Bucket size — shown in the header pill. Tab-agnostic (from `PRManager`) so
    /// it equals the menu-bar badge on either tab.
    let needsHumanCount: Int
    /// Count of the scope+draft-filtered population that is NOT in the bucket.
    let handledCount: Int
    /// Whether the bucket is expanded. Owned by `MenuBarView`; the shared scroll
    /// region shows the rows when this is true.
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if handledCount > 0 {
                handledSummaryRow
            }
        }
    }

    /// The header doubles as the collapse/expand control. It reads
    /// "Needs a Human · N" and toggles `expanded`.
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
                Text("\(needsHumanCount)")
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
        .help(expanded ? "Hide the Needs-a-Human list" : "Show \(needsHumanCount) PRs that need a human")
    }

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

// MARK: - NeedsHumanRowsView

/// The "Needs a Human" bucket ROWS. Rendered INSIDE the shared scroll region by
/// `MenuBarView` — it is a plain `LazyVStack` with NO ScrollView and NO fixed
/// frame, so it contributes its natural height to the single measured scroll
/// region and can never declare an independent (potentially oversized) frame.
struct NeedsHumanRowsView: View {
    /// The tab-agnostic "needs a human" set, computed once on `PRManager`.
    let needsHumanPRs: [PRSnapshot]
    let myLogin: String
    /// Whether merge conflicts count toward the bucket. Sourced from settings.
    let includeConflicts: Bool
    /// Shared row layout metrics (compact vs comfortable).
    let metrics: RowMetrics
    /// Whether write actions are enabled — drives the inline Merge button style.
    let writeActionsEnabled: Bool
    /// Requests a merge for the given PR. Routed by the owner (`MenuBarView`)
    /// through the SAME write-action confirm + `performAction(.merge)` path used
    /// everywhere else. Rendered only on `readyToMerge` rows.
    let onMerge: (PRSnapshot) -> Void
    @ObservedObject var trustLedger: TrustLedgerStore

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
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sortedNeedsHuman, id: \.nodeId) { pr in
                needsHumanRow(pr)
                Divider().padding(.leading, metrics.dividerLeadingInset)
            }
        }
    }

    // MARK: - PR row

    private func needsHumanRow(_ pr: PRSnapshot) -> some View {
        Button {
            if let url = URL(string: pr.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            let trustTier: TrustTier = trustLedger.tier(for: pr.author)
            let isDraft = pr.classifiedState == .draft
            let m = metrics
            HStack(alignment: .top, spacing: m.rowHStackSpacing) {
                triggerIcon(for: pr)
                    .frame(width: m.leadingIconSize, height: m.leadingIconSize)

                VStack(alignment: .leading, spacing: m.titleMetadataSpacing) {
                    Text(pr.title)
                        .font(.callout)
                        .lineLimit(m.titleLineLimit)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(verbatim: "\(pr.repoFullName) #\(pr.number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isDraft {
                            DraftBadge()
                        }
                        TrustBadgeView(tier: trustTier)
                        ReviewSourceBadge(pr: pr, myLogin: myLogin)
                        FeedbackBadge(pr: pr)
                        triggerLabels(for: pr)
                    }
                }

                // Inline Merge — shown only on ready-to-merge rows. Separate hit
                // area so it never triggers the row's click-to-open; routes
                // through the shared merge confirm path (owned by MenuBarView).
                if pr.readyToMerge {
                    Spacer(minLength: 4)
                    MergeButton(
                        writeActionsEnabled: writeActionsEnabled,
                        onMerge: { onMerge(pr) }
                    )
                }
            }
            // Drafts read as lower-priority: mute the whole row while keeping
            // it fully clickable/openable.
            .opacity(isDraft ? 0.6 : 1.0)
            .padding(.horizontal, 12)
            .padding(.vertical, metrics.rowVerticalPadding)
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

}
