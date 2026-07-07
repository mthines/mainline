import SwiftUI
import AppKit

// MARK: - RowMetrics

/// Shared layout metrics for PR rows, driven by `settings.compactRows`. Used by
/// the `TriageDeckView` deck rows so every actionability section stays visually
/// consistent at either density.
struct RowMetrics {
    /// Title line limit (1 = single-line truncating tail; 2 = comfortable).
    let titleLineLimit: Int
    /// Vertical padding applied to each row.
    let rowVerticalPadding: CGFloat
    /// Spacing between the title and the metadata line.
    let titleMetadataSpacing: CGFloat
    /// Square frame size for the leading STATUS icon (CI / trigger). This is the
    /// single "icon frame" every PR row shares — see `LeadingColumn`.
    let leadingIconSize: CGFloat
    /// Spacing between the leading icons and the text column.
    let rowHStackSpacing: CGFloat
    /// Top padding for per-state section headers.
    let sectionHeaderTopPadding: CGFloat
    /// Bottom padding for per-state section headers.
    let sectionHeaderBottomPadding: CGFloat

    /// Fixed width of the leading UNREAD-DOT slot, reserved on EVERY PR row whether
    /// or not an unread dot is shown, so the status icon that follows it starts at
    /// the same x in every section. The unread dot itself is 7pt; the slot is a
    /// touch wider to give the dot breathing room and keep the icon column stable.
    let unreadDotSlotWidth: CGFloat

    /// Horizontal padding applied to the leading/trailing edge of every PR row and
    /// section header. Kept on `RowMetrics` so headers, rows, dividers and the
    /// "looking good" summary all read from ONE constant.
    static let horizontalPadding: CGFloat = 12

    static let compact = RowMetrics(
        titleLineLimit: 1,
        rowVerticalPadding: 3,
        titleMetadataSpacing: 1,
        leadingIconSize: 16,
        rowHStackSpacing: 6,
        sectionHeaderTopPadding: 10,
        sectionHeaderBottomPadding: 8,
        unreadDotSlotWidth: 10
    )

    static let comfortable = RowMetrics(
        titleLineLimit: 2,
        rowVerticalPadding: 6,
        titleMetadataSpacing: 2,
        leadingIconSize: 20,
        rowHStackSpacing: 8,
        sectionHeaderTopPadding: 14,
        sectionHeaderBottomPadding: 10,
        unreadDotSlotWidth: 12
    )

    static func forCompact(_ compact: Bool) -> RowMetrics {
        compact ? .compact : .comfortable
    }

    /// The x at which row CONTENT (the title/metadata column) begins, measured from
    /// the row's leading edge INCLUDING the row's horizontal padding. This is the
    /// single source of truth for aligning the row divider's leading inset so it
    /// starts under the title in every section and at both densities.
    ///
    ///   horizontalPadding + unreadDotSlot + spacing + iconFrame + spacing
    func dividerInset(forHorizontalPadding hPad: CGFloat = RowMetrics.horizontalPadding) -> CGFloat {
        hPad + unreadDotSlotWidth + rowHStackSpacing + leadingIconSize + rowHStackSpacing
    }
}

// MARK: - LeadingColumn

/// The single, shared leading structure for EVERY PR row — every actionability
/// section's deck rows compose it so their unread-dot slot and status icon (and
/// therefore their titles) line up in one column at both densities.
///
/// Layout (left → right), all inside the row's `.padding(.horizontal, RowMetrics.horizontalPadding)`:
///   [unread-dot slot: FIXED `unreadDotSlotWidth`, renders the dot when `isUnread`,
///    else an equal-width empty spacer]
///   [status-icon slot: FIXED `leadingIconSize` == the shared icon frame]
///
/// The HStack that hosts this uses `metrics.rowHStackSpacing`, matching
/// `dividerInset(forHorizontalPadding:)`, so the content column and the divider
/// share one measurement.
struct LeadingColumn<Icon: View>: View {
    let metrics: RowMetrics
    let isUnread: Bool
    /// The status-icon view (CI icon for deck rows, trigger icon for needs-human).
    /// It is framed to the shared `leadingIconSize` by this column so callers don't
    /// have to remember to.
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        // Unread-dot slot — ALWAYS reserved at a fixed width so the icon that
        // follows starts at the same x whether or not a dot is shown.
        ZStack {
            if isUnread {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unread")
            } else {
                Color.clear
            }
        }
        .frame(width: metrics.unreadDotSlotWidth)

        // Status-icon slot — fixed square == the shared icon frame.
        icon()
            .frame(width: metrics.leadingIconSize, height: metrics.leadingIconSize)
    }
}

// MARK: - TriageDeckView

/// Keyboard-driven triage deck. Manages selection, key bindings,
/// single-key verb dispatch, multi-select, diff preview, command palette,
/// and undo toast stack.
///
/// Key bindings:
///   J / ↓  — next PR
///   K / ↑  — previous PR
///   Space  — view diff (DiffPreviewView)
///   A      — approve (write-gated)
///   M      — merge (write-gated)
///   R      — request changes (write-gated)
///   S      — snooze 1h
///   E      — mark seen
///   X      — dismiss
///   V      — toggle multi-select mode
///   ⌘K     — command palette
///   ⌘Z     — undo last action
struct TriageDeckView: View {
    let prs: [PRSnapshot]
    @ObservedObject var manager: PRManager
    @ObservedObject var settings: MainlineSettings

    @State private var selectedIndex: Int = 0
    @State private var hoveredRowID: String? = nil
    @State private var showDiff: Bool = false
    @State private var showCommandPalette: Bool = false
    @State private var multiSelectMode: Bool = false
    @State private var selectedPRs: Set<String> = []   // nodeIds
    @State private var undoEntries: [UndoEntry] = []
    @State private var eventMonitor: Any? = nil

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if prs.isEmpty {
                    emptyState
                } else {
                    prList
                }
            }
            .overlay(alignment: .center) {
                if showDiff, let pr = focusedPR {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { showDiff = false }
                    DiffPreviewView(
                        pr: pr,
                        client: manager.client,
                        isPresented: $showDiff
                    )
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(10)
                }

                if showCommandPalette, let pr = focusedPR {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                        .onTapGesture { showCommandPalette = false }
                    CommandPaletteView(
                        pr: pr,
                        writeActionsEnabled: settings.writeActionsEnabled,
                        onAction: { action in
                            handleTriageAction(action, on: pr)
                        },
                        isPresented: $showCommandPalette,
                        manager: manager
                    )
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(10)
                }
            }

            // Undo toast stack
            if !undoEntries.isEmpty {
                UndoToastView(entries: $undoEntries)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(5)
            }
        }
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    // MARK: - PR list

    /// PRs in canonical triage order — Open/InReview/Approved above Draft,
    /// then most-recently-updated first. Drafts never appear above open PRs.
    /// This flat order is the index space that J/K keyboard navigation walks,
    /// even though rows are displayed grouped into collapsible sections.
    private var orderedPRs: [PRSnapshot] {
        prs.sorted(by: PRSnapshot.triageOrder)
    }

    /// The actionability section a PR is grouped under for DISPLAY. Delegates to
    /// `PRSnapshot.actionGroup(splitDrafts:)` — the single source of truth — so the
    /// list groups by "does this still need me?" (Needs attention / Ready to merge /
    /// Waiting) rather than raw review state. Drafts either form their own section
    /// (`splitDrafts`) or mix into their actionability group (default).
    private func groupFor(_ pr: PRSnapshot) -> ActionGroup {
        pr.actionGroup(splitDrafts: settings.splitDrafts)
    }

    /// Grouped sections in canonical actionability order, excluding empty ones:
    /// Needs attention → Ready to merge → Waiting → Draft → Merged → Closed →
    /// Postponed. The active `prs` (already snooze-excluded upstream) fill the
    /// actionability groups; the trailing `.postponed` section is appended from
    /// `manager.postponedPRs` (snoozed & not expired for the current tab + scope),
    /// so it is always LAST and its membership is independent of actionability.
    private var sections: [(group: ActionGroup, prs: [PRSnapshot])] {
        let grouped = Dictionary(grouping: orderedPRs, by: { groupFor($0) })
        var result = ActionGroup.allCases
            .filter { $0 != .postponed }
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { group -> (group: ActionGroup, prs: [PRSnapshot])? in
                guard let prs = grouped[group], !prs.isEmpty else { return nil }
                return (group, prs.sorted(by: PRSnapshot.triageOrder))
            }

        let postponed = manager.postponedPRs.sorted(by: postponedWakeOrder)
        if !postponed.isEmpty {
            result.append((.postponed, postponed))
        }

        // Done is the LOWEST-priority section — appended LAST, after Postponed.
        // Sourced from the display-only `doneViewPRs` (merged/closed for the
        // current tab + scope), sorted most-recently-updated first. Collapsed by
        // default (see `expansionBinding`).
        let done = manager.doneViewPRs.sorted { $0.updatedAt > $1.updatedAt }
        if !done.isEmpty {
            result.append((.done, done))
        }
        return result
    }

    /// Ordering for the Postponed section: soonest wake first, then title.
    private func postponedWakeOrder(_ lhs: PRSnapshot, _ rhs: PRSnapshot) -> Bool {
        let lw = manager.snoozeStore.wakeTime(nodeId: lhs.nodeId) ?? .distantFuture
        let rw = manager.snoozeStore.wakeTime(nodeId: rhs.nodeId) ?? .distantFuture
        if lw != rw { return lw < rw }
        return lhs.title < rhs.title
    }

    /// The single main list: the keyboard-navigable deck grouped into
    /// collapsible actionability sections. Row focus indices map back into the flat
    /// `orderedPRs` array so J/K navigation is unaffected by grouping.
    ///
    /// Renders as a plain (NON-lazy, NON-scrolling) `VStack`: this view is hosted
    /// inside `MenuBarView`'s SINGLE outer `ScrollView`, so it must contribute its
    /// FULL natural height to the layout. A nested inner `ScrollView` here would be
    /// greedy — it would fill whatever height the outer offers while the outer's
    /// frame is derived from measuring content that CONTAINS this scroll view,
    /// creating a mutual layout dependency (infinite re-layout → beachball freeze)
    /// and hiding expanded rows below the small measured frame. Using an eager
    /// `VStack` makes every row (including a freshly expanded Postponed/Done bucket)
    /// realized and measured, so expanding a section grows the measured body height
    /// and the outer region follows it up to the cap, then scrolls.
    private var prList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.group) { section in
                sectionView(group: section.group, prs: section.prs)
            }
        }
    }

    /// Row layout metrics for the current density.
    private var metrics: RowMetrics {
        RowMetrics.forCompact(settings.compactRows)
    }

    @ViewBuilder
    private func sectionView(group: ActionGroup, prs sectionPRs: [PRSnapshot]) -> some View {
        let expansion = expansionBinding(for: group)
        // Whole-header tap toggles the section (label + count + chevron), matching
        // the Needs-a-Human header. Replaces DisclosureGroup so tapping the text or
        // count — not just the triangle — expands/collapses.
        Button {
            // No withAnimation: animating the expand makes the body height change
            // every frame, which the GeometryReader/BodyHeightKey → .frame(height:)
            // path re-measures every frame → per-frame popover resize → layout loop
            // → beachball. Toggle instantly so height changes in a single step.
            expansion.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("\(sectionPRs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Image(systemName: expansion.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.top, metrics.sectionHeaderTopPadding)
            .padding(.bottom, metrics.sectionHeaderBottomPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expansion.wrappedValue ? "Collapse \(group.title)" : "Expand \(group.title)")

        if expansion.wrappedValue {
            ForEach(sectionPRs, id: \.nodeId) { pr in
                if group == .postponed {
                    postponedRow(pr: pr)
                } else if group == .done {
                    doneRow(pr: pr)
                } else {
                    deckRow(pr: pr, index: flatIndex(of: pr))
                }
                Divider().padding(.leading, metrics.dividerInset())
            }
        }
    }

    /// Index of a PR within the flat `orderedPRs` array (keyboard index space).
    private func flatIndex(of pr: PRSnapshot) -> Int {
        orderedPRs.firstIndex(where: { $0.nodeId == pr.nodeId }) ?? 0
    }

    /// Collapse state persisted to MainlineSettings, keyed by `ActionGroup`.
    ///
    /// Every group EXCEPT `.postponed` / `.done` is expanded by default (a group is
    /// collapsed only when present in `collapsedSections`). Those two invert this:
    /// they are COLLAPSED by default and the set instead records that the user
    /// explicitly EXPANDED them — so a first-run user sees Postponed and Done
    /// closed, but the choice still persists once toggled. Reuses the same
    /// `collapsedSections` store (no new key).
    private func expansionBinding(for group: ActionGroup) -> Binding<Bool> {
        // Postponed and Done both INVERT the default: they are COLLAPSED by default,
        // and the `collapsedSections` set instead records that the user explicitly
        // EXPANDED them (so the choice persists once toggled). Every other group is
        // expanded by default and the set records collapse.
        if group == .postponed || group == .done {
            return Binding(
                get: { settings.collapsedSections.contains(group) },
                set: { expanded in
                    var set = settings.collapsedSections
                    if expanded { set.insert(group) } else { set.remove(group) }
                    settings.collapsedSections = set
                }
            )
        }
        return Binding(
            get: { !settings.collapsedSections.contains(group) },
            set: { expanded in
                var collapsed = settings.collapsedSections
                if expanded { collapsed.remove(group) } else { collapsed.insert(group) }
                settings.collapsedSections = collapsed
            }
        )
    }

    private func deckRow(pr: PRSnapshot, index: Int) -> some View {
        let isFocused = index == selectedIndex
        let isSelected = selectedPRs.contains(pr.nodeId)
        let isDraft = pr.isDraft
        // "Later" is HOVER-ONLY — it reveals when the pointer is over this row and
        // never on the keyboard-focused row (keyboard users snooze via `S` / ⌘K).
        let isHovered = hoveredRowID == pr.nodeId
        let m = metrics
        return Button {
            handleRowClick(pr: pr, index: index)
        } label: {
            HStack(alignment: .top, spacing: m.rowHStackSpacing) {
                // Shared leading structure: [unread-dot slot][status-icon slot].
                // Identical to the Needs-a-Human rows so the CI icon and the title
                // start at the same x in every section.
                LeadingColumn(
                    metrics: m,
                    isUnread: manager.unreadPRIds.contains(pr.nodeId)
                ) {
                    // Drafts show a muted grey draft glyph in the status-icon slot
                    // instead of the CI-status icon, reinforcing the Draft badge +
                    // dimmed row. Non-draft PRs keep the CI icon exactly as-is.
                    if isDraft {
                        draftIcon
                    } else {
                        ciIcon(for: pr.ciStatus)
                    }
                }

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
                        TrustBadgeView(tier: manager.trustLedger.tier(for: pr.author))
                        if settings.selectedTab == .forMe {
                            ReviewSourceBadge(pr: pr, myLogin: settings.githubUsername)
                        }
                        FeedbackBadge(pr: pr)
                    }
                }

                Spacer(minLength: 4)

                // Inline Merge — shown only on ready-to-merge rows, and only while
                // NOT hovered. On hover it is hidden here and re-drawn inside the
                // trailing overlay cluster so Later never sits on top of Merge.
                // Separate borderless hit area (never triggers row click-to-open);
                // routes through the SAME confirm + performAction path as the M verb.
                if pr.readyToMerge {
                    MergeButton(
                        writeActionsEnabled: settings.writeActionsEnabled,
                        onMerge: { dispatchVerb(.merge(pr)) }
                    )
                    .opacity(isHovered ? 0 : 1)
                    .allowsHitTesting(!isHovered)
                }
            }
            // Drafts read as lower-priority: mute the row CONTENT only. Applied
            // HERE — before the hover overlay — so the draft dim never reaches the
            // hover action cluster; Later/Merge stay full-opacity on draft rows.
            .opacity(isDraft ? 0.6 : 1.0)
            // On hover, dissolve the trailing edge of the row CONTENT (title +
            // metadata) to transparent with an alpha mask so the text fades out
            // smoothly UNDER the trailing action pill — letting the panel background
            // show through with no colored block or hard seam. Most of the row stays
            // fully visible; only the trailing region (~the pill width) fades. When
            // NOT hovered, no mask is applied and the title stays full-width/opaque.
            .mask(alignment: .center) {
                if isHovered {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.80),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Rectangle()
                }
            }
            // The title/content extends the FULL row width — no reserved space for
            // the Later button. The hover actions are drawn as a trailing overlay
            // on top of the faded area, vertically CENTERED within the row content
            // and compact so the capsule sits on its OWN row with no vertical bleed
            // into neighbours. Attached to the row content HStack — BEFORE the row's
            // vertical padding and BEFORE the section's trailing Divider — so its
            // bounds equal the visible row content and never include the divider's
            // height. Placed AFTER the draft opacity so the cluster renders fully
            // opaque even on draft rows.
            .overlay(alignment: .trailing) {
                if isHovered {
                    hoverActionsCluster(for: pr)
                        .transition(.opacity)
                }
            }
            // Near-instant fade in/out so the hover reveal feels snappy.
            .animation(.easeOut(duration: 0.05), value: hoveredRowID)
            // Track the hovered row so its Later button reveals on hover. Clearing
            // only when THIS row was the hovered one avoids a late "mouse exited"
            // from a previous row wiping a newer row's hover state.
            .onHover { hovering in
                hoveredRowID = hovering ? pr.nodeId : (hoveredRowID == pr.nodeId ? nil : hoveredRowID)
            }
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, m.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? Color.accentColor.opacity(0.08) : .clear)
            // Focus / multi-select indication rendered as a leading accent bar in
            // the row's leading padding, so it never consumes a layout column and
            // the shared LeadingColumn stays aligned with the Needs-a-Human rows.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected
                          ? Color.accentColor
                          : (isFocused ? Color.accentColor.opacity(0.4) : Color.clear))
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The hover-only trailing action pill drawn as an `.overlay` on top of a
    /// deck row's full-width title. Contains "Later" (always) plus "Merge" (only
    /// on ready-to-merge rows) so the two never overlap — on ready rows the
    /// in-flow Merge is hidden while hovered and re-drawn here beside Later.
    ///
    /// There is NO separate leading gradient block: the row content itself is
    /// alpha-masked to fade to transparent under this pill (see the `.mask` in
    /// `deckRow`), so the title dissolves smoothly beneath the buttons with no
    /// colored seam. The pill keeps a subtle `.regularMaterial` capsule for its
    /// OWN label legibility over whatever title remains behind it.
    @ViewBuilder
    private func hoverActionsCluster(for pr: PRSnapshot) -> some View {
        // Compact fixed height for the pill so it matches the button capsule —
        // NOT the full row+divider height — and stays vertically centered within
        // the row content, never bleeding into neighbours.
        let clusterHeight: CGFloat = 24
        HStack(spacing: 6) {
            LaterButton(onPostpone: { duration in postpone(pr, for: duration) })

            // On ready rows, re-draw Merge here beside Later so both actions
            // share the hover background and Later never covers Merge.
            if pr.readyToMerge {
                MergeButton(
                    writeActionsEnabled: settings.writeActionsEnabled,
                    onMerge: { dispatchVerb(.merge(pr)) }
                )
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        // Fixed compact height keeps the capsule on its own row; `.center`
        // alignment in the enclosing `.overlay(alignment: .trailing)` then centres
        // it vertically within the row content.
        .frame(height: clusterHeight)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 4)
        .fixedSize()
    }

    /// A row in the collapsed "Postponed" section. Reuses the shared
    /// `LeadingColumn` + `RowMetrics` so it aligns with every other section, shows
    /// a relative "wakes in 3h" / "wakes tomorrow" label derived from the wake
    /// date, and a Resume button that unsnoozes the PR (returning it to its normal
    /// group immediately). Clicking the row body opens the PR in the browser, like
    /// the deck rows. Rendered inside the SAME single scroll region — no nested
    /// ScrollView — preserving the crash-safe height architecture.
    private func postponedRow(pr: PRSnapshot) -> some View {
        let m = metrics
        let wake = manager.snoozeStore.wakeTime(nodeId: pr.nodeId)
        return Button {
            if let url = URL(string: pr.htmlUrl) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: m.rowHStackSpacing) {
                LeadingColumn(metrics: m, isUnread: false) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Postponed")
                }

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
                        if let wake {
                            Text(humanizedWake(from: wake))
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(nsColor: .systemIndigo).opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Color(nsColor: .systemIndigo))
                                .accessibilityLabel(humanizedWake(from: wake))
                        }
                    }
                }

                Spacer(minLength: 4)

                ResumeButton(onResume: { resume(pr) })
            }
            .opacity(0.85)
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, m.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A row in the collapsed "Done" section (recently merged / closed PRs). These
    /// are DISPLAY-ONLY: no keyboard focus (they are not in the `orderedPRs` index
    /// space), no unread dot, and NO hover action cluster — a finished PR has no
    /// Merge / Later action. Reuses the shared `LeadingColumn` + `RowMetrics` so it
    /// aligns with every other section, shows the purple merged / grey closed status
    /// icon in the leading slot, and opens the PR in the browser on click. Rendered
    /// inside the SAME single scroll region — no nested ScrollView.
    private func doneRow(pr: PRSnapshot) -> some View {
        let m = metrics
        return Button {
            if let url = URL(string: pr.htmlUrl) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: m.rowHStackSpacing) {
                LeadingColumn(metrics: m, isUnread: false) {
                    doneStatusIcon(for: pr)
                }

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
                        DoneBadge(pr: pr)
                        if settings.selectedTab == .forMe {
                            ReviewSourceBadge(pr: pr, myLogin: settings.githubUsername)
                        }
                    }
                }

                Spacer(minLength: 4)
            }
            // Finished PRs read as lower priority — mute the whole row.
            .opacity(0.7)
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, m.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A mouse click focuses the row and — unless multi-select is active —
    /// opens the PR in the browser, matching the other row lists. In
    /// multi-select mode a click toggles membership instead of opening.
    /// Keyboard J/K only moves focus (never opens); that path never calls this.
    private func handleRowClick(pr: PRSnapshot, index: Int) {
        selectedIndex = index
        if multiSelectMode {
            if selectedPRs.contains(pr.nodeId) {
                selectedPRs.remove(pr.nodeId)
            } else {
                selectedPRs.insert(pr.nodeId)
            }
        } else {
            if let url = URL(string: pr.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Draft icon

    /// Muted grey draft glyph shown in the leading status-icon slot for draft PRs,
    /// in place of the CI-status icon. Framed by `LeadingColumn` to the shared
    /// `leadingIconSize`, so alignment with non-draft rows is unchanged.
    private var draftIcon: some View {
        Image(systemName: "pencil.circle")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Draft")
    }

    // MARK: - Done status icon (merged = purple, closed = grey)

    /// Leading status icon for a completed PR, OVERRIDING the CI icon:
    ///   - merged (`pr.merged == true`)   → purple `arrow.triangle.merge` ("Merged")
    ///   - closed-not-merged (`closed && !merged`) → muted grey `xmark.circle`
    ///     ("Closed").
    /// Falls back to the CI icon for anything unexpected (should not occur in the
    /// Done set, which only contains merged/closed PRs).
    @ViewBuilder
    private func doneStatusIcon(for pr: PRSnapshot) -> some View {
        if pr.merged {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Color(nsColor: .systemPurple))
                .accessibilityLabel("Merged")
        } else if pr.closed {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Closed")
        } else {
            ciIcon(for: pr.ciStatus)
        }
    }

    // MARK: - CI icon (accessibilityLabel on every state)

    @ViewBuilder
    private func ciIcon(for ciStatus: CIStatus) -> some View {
        switch ciStatus {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("CI passed")
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("CI failed")
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("CI error")
        case .pending:
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("CI pending")
        case .unknown:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .accessibilityLabel("CI status unknown")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Queue clear")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
            Spacer()
        }
    }

    // MARK: - Focused PR

    private var focusedPR: PRSnapshot? {
        let ordered = orderedPRs
        guard selectedIndex < ordered.count else { return nil }
        return ordered[selectedIndex]
    }

    // MARK: - Key monitor (macOS 13 compatible)

    private func installKeyMonitor() {
        // Force first-responder so key events reach the panel
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(NSApp.keyWindow?.contentView)
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            return self.handleKeyDown(event)
        }
    }

    private func removeKeyMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Don't intercept when overlays are showing (they handle their own keys)
        if showDiff || showCommandPalette { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let cmd = event.modifierFlags.contains(.command)

        switch (chars, cmd) {
        // Navigation
        case ("j", false), ("\u{F701}", false):  // j or ↓
            moveDown()
            return nil
        case ("k", false), ("\u{F700}", false):  // k or ↑
            moveUp()
            return nil

        // Diff preview
        case (" ", false):
            showDiff = true
            return nil

        // Command palette
        case ("k", true):
            showCommandPalette = true
            return nil

        // Undo
        case ("z", true):
            undoLast()
            return nil

        // Write verbs (gated by writeActionsEnabled)
        case ("a", false):
            if let pr = focusedPR { dispatchVerb(.approve(pr)) }
            return nil
        case ("m", false):
            if let pr = focusedPR { dispatchVerb(.merge(pr)) }
            return nil
        case ("r", false):
            if let pr = focusedPR { dispatchVerb(.requestChanges(pr)) }
            return nil

        // Non-write verbs
        case ("s", false):
            // Quick "Later" — postpone with the default duration (1 day). The clock
            // button + command palette expose the full duration menu.
            if let pr = focusedPR {
                postpone(pr, for: .quickDefault)
            }
            return nil
        case ("e", false):
            if let pr = focusedPR {
                Task { await manager.performAction(.markSeen(pr)) }
                pushUndo(label: "Marked seen: \(pr.title)", pr: pr) {}
            }
            return nil
        case ("x", false):
            if let pr = focusedPR {
                Task { await manager.performAction(.dismiss(pr)) }
                pushUndo(label: "Dismissed \(pr.title)", pr: pr) {}
            }
            return nil

        // Multi-select toggle
        case ("v", false):
            multiSelectMode.toggle()
            return nil

        default:
            return event
        }
    }

    private func moveDown() {
        guard !prs.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, prs.count - 1)
    }

    private func moveUp() {
        guard !prs.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    // MARK: - Verb dispatch

    private func dispatchVerb(_ action: WriteAction) {
        guard settings.writeActionsEnabled else {
            // Show disabled-state alert
            let alert = NSAlert()
            alert.messageText = "Write Actions Disabled"
            alert.informativeText = "Enable \"Write Actions\" in Settings to use approve, merge, and request-changes."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        // Require confirmation for write actions via an app-modal NSAlert.
        // A SwiftUI `.confirmationDialog` inside the MenuBarExtra popover dismisses
        // the popover before the action fires, so the merge/approve never happens
        // ("closes instead of merges"). NSAlert is app-modal and independent of the
        // popover's lifecycle, so the action reliably runs.
        let copy = confirmCopy(for: action)
        let alert = NSAlert()
        alert.messageText = copy.message
        alert.informativeText = "This performs the action on GitHub."
        alert.alertStyle = .warning
        alert.addButton(withTitle: copy.button)   // default — Return
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await manager.performAction(action) }
    }

    // MARK: - Triage action from command palette

    private func handleTriageAction(_ action: TriageAction, on pr: PRSnapshot) {
        switch action {
        case .approve:
            dispatchVerb(.approve(pr))
        case .merge:
            dispatchVerb(.merge(pr))
        case .requestChanges:
            dispatchVerb(.requestChanges(pr))
        case .snooze(let duration):
            postpone(pr, for: duration)
        case .markSeen:
            Task { await manager.performAction(.markSeen(pr)) }
            pushUndo(label: "Marked seen: \(pr.title)", pr: pr) {}
        case .dismiss:
            Task { await manager.performAction(.dismiss(pr)) }
            pushUndo(label: "Dismissed \(pr.title)", pr: pr) {}
        case .viewDiff:
            showDiff = true
        case .openInBrowser:
            if let url = URL(string: pr.htmlUrl) { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: - Undo

    private func pushUndo(label: String, pr: PRSnapshot, undoFn: @escaping () -> Void) {
        let entry = UndoEntry(label: label, pr: pr, undo: undoFn)
        withAnimation { undoEntries.append(entry) }
        // Auto-dismiss after 8s
        let id = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            withAnimation { undoEntries.removeAll { $0.id == id } }
        }
    }

    private func undoLast() {
        guard let last = undoEntries.last else { return }
        last.undo()
        withAnimation { undoEntries.removeLast() }
    }

    // MARK: - Postpone / Resume

    /// Postpones (snoozes) a PR for the given duration. The PR immediately leaves
    /// its actionability group (excluded from `currentViewPRs`) and moves to the
    /// collapsed "Postponed" section. Pushes an undoable toast that resumes it.
    private func postpone(_ pr: PRSnapshot, for duration: SnoozeDuration) {
        Task { await manager.performAction(.snooze(pr, until: Date().addingTimeInterval(duration.interval))) }
        pushUndo(label: "Postponed \(pr.title) · \(duration.title)", pr: pr) {
            Task { await manager.performAction(.unsnooze(pr)) }
        }
    }

    /// Resumes (unsnoozes) a postponed PR — it returns to its normal group
    /// immediately.
    private func resume(_ pr: PRSnapshot) {
        Task { await manager.performAction(.unsnooze(pr)) }
    }

    // MARK: - Confirmation copy

    private func confirmCopy(for action: WriteAction) -> (message: String, button: String) {
        switch action {
        case .approve(let pr):        return ("Approve \"\(pr.title)\"?", "Approve")
        case .merge(let pr):          return ("Merge \"\(pr.title)\"?", "Merge")
        case .requestChanges(let pr): return ("Request changes on \"\(pr.title)\"?", "Request Changes")
        default:                      return ("Perform this action?", "Confirm")
        }
    }

    // MARK: - Multi-select bulk verbs

    /// Returns the PRs currently in the multi-select set, in display order.
    private var selectedPRList: [PRSnapshot] {
        prs.filter { selectedPRs.contains($0.nodeId) }
    }
}

// MARK: - MergeButton

/// Compact inline "Merge" button rendered on the trailing side of a
/// ready-to-merge PR row. It has its own borderless hit area so a tap never
/// triggers the row's click-to-open; the
/// `onMerge` closure routes through the SAME write-action confirm path used by
/// the `M` keyboard verb / command palette (`dispatchVerb(.merge)` →
/// confirmation dialog → `performAction(.merge)`).
///
/// When write actions are disabled the button stays visible (discoverable) and
/// tapping it surfaces the "enable write actions" guidance via the shared
/// dispatch path; a `.help` tooltip states the same up front.
struct MergeButton: View {
    let writeActionsEnabled: Bool
    let onMerge: () -> Void

    var body: some View {
        Button(action: onMerge) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.caption2)
                Text("Merge")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Color(nsColor: .systemGreen).opacity(writeActionsEnabled ? 0.18 : 0.10),
                in: Capsule()
            )
            .foregroundStyle(
                writeActionsEnabled ? Color(nsColor: .systemGreen) : Color.secondary
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .help(writeActionsEnabled
              ? "Merge this PR"
              : "Enable write actions in Settings to merge")
        .accessibilityLabel("Merge")
    }
}

// MARK: - LaterButton

/// Compact inline "Later" (postpone) control rendered on the trailing side of a
/// deck row. It is a SwiftUI `Menu` styled as a small clock capsule with its OWN
/// borderless hit area, so opening it or picking a duration never triggers the
/// row's click-to-open (same isolation pattern as `MergeButton`). Picking a
/// duration calls `onPostpone`, which snoozes the PR and moves it to the
/// "Postponed" section.
struct LaterButton: View {
    let onPostpone: (SnoozeDuration) -> Void

    var body: some View {
        Menu {
            ForEach(SnoozeDuration.allCases) { duration in
                Button(duration.title) { onPostpone(duration) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                Text("Later")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .systemIndigo).opacity(0.15), in: Capsule())
            .foregroundStyle(Color(nsColor: .systemIndigo))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Postpone this PR for later")
        .accessibilityLabel("Later")
    }
}

// MARK: - ResumeButton

/// Compact inline "Resume" control on a Postponed row. Its own borderless hit
/// area so tapping it never opens the PR; calls `onResume` to unsnooze the PR,
/// returning it to its normal actionability group immediately.
struct ResumeButton: View {
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption2)
                Text("Resume")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .systemBlue).opacity(0.15), in: Capsule())
            .foregroundStyle(Color(nsColor: .systemBlue))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .help("Resume now — return this PR to its group")
        .accessibilityLabel("Resume")
    }
}

// MARK: - DraftBadge

/// Compact gray/secondary pill marking a PR as a draft. Rendered on the
/// repo/#number metadata line alongside the trust/feedback/trigger tags, using
/// the same visual style so drafts are obvious while scrolling.
struct DraftBadge: View {
    var body: some View {
        Text("Draft")
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(nsColor: .secondaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Draft")
    }
}

// MARK: - DoneBadge

/// Compact pill marking a completed PR as Merged (purple) or Closed (grey),
/// rendered on the repo/#number metadata line of a Done-section row. Mirrors the
/// leading status icon's color so the row's "merged vs. closed" state reads at a
/// glance without the icon.
struct DoneBadge: View {
    let pr: PRSnapshot

    var body: some View {
        if pr.merged {
            badge(text: "Merged", color: Color(nsColor: .systemPurple))
        } else if pr.closed {
            badge(text: "Closed", color: Color(nsColor: .secondaryLabelColor))
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
            .accessibilityLabel(text)
    }
}

// MARK: - FeedbackBadge

/// Compact per-row badge flagging review feedback on a PR. Rendered on the
/// repo/#number metadata line alongside the trust and review-source badges.
///
/// Priority:
///   1. `reviewDecision == .changesRequested` → red "changes" tag (a reviewer
///      formally requested changes — needs your attention).
///   2. else if `unresolvedThreadCount > 0` → an amber "N unresolved" pending tag
///      (open conversations still need a reply/resolution — this PR still needs
///      you). Chosen over the neutral comment badge so open threads stand out
///      within a group.
///   3. else if review activity exists — `reviewState == .changesRequested`
///      (reviews present but no aggregate decision) OR `commentCount > 0` →
///      a subtle secondary comment badge (bubble icon + count, count omitted
///      when 0).
///   4. else → nothing.
struct FeedbackBadge: View {
    let pr: PRSnapshot

    var body: some View {
        if pr.reviewDecision == .changesRequested {
            Text("changes")
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(nsColor: .systemRed).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(Color(nsColor: .systemRed))
                .accessibilityLabel("Changes requested")
        } else if pr.unresolvedThreadCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.caption2)
                Text("\(pr.unresolvedThreadCount) unresolved")
                    .font(.caption2)
            }
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(nsColor: .systemOrange).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .accessibilityLabel("\(pr.unresolvedThreadCount) unresolved conversation\(pr.unresolvedThreadCount == 1 ? "" : "s")")
        } else if pr.reviewState == .changesRequested || pr.commentCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left")
                    .font(.caption2)
                if pr.commentCount > 0 {
                    Text("\(pr.commentCount)")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                pr.commentCount > 0
                    ? "\(pr.commentCount) comment\(pr.commentCount == 1 ? "" : "s")"
                    : "Has review feedback"
            )
        }
    }
}

// MARK: - ReviewSourceBadge

/// Small badge distinguishing a DIRECT ("you", accent) review request from a
/// TEAM one (team slug, secondary). Rendered on For-me rows next to the
/// repo/#number line. Hidden when the PR is not review-requested.
struct ReviewSourceBadge: View {
    let pr: PRSnapshot
    let myLogin: String

    var body: some View {
        switch pr.reviewRequestSource(myLogin: myLogin) {
        case .direct:
            badge(text: "you", color: Color.accentColor)
        case .team:
            // Prefer showing the team slug; fall back to a generic "team" label.
            badge(text: pr.requestedTeams.first ?? "team", color: Color(nsColor: .secondaryLabelColor))
        case .none:
            EmptyView()
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
            .accessibilityLabel(text == "you" ? "Directly requested" : "Team requested: \(text)")
    }
}
