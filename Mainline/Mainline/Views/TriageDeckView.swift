import SwiftUI
import AppKit

// MARK: - TriageAction

/// All actions available for a PR in the triage deck. Surfaced via the row
/// context menu (right-click) and dispatched through `handleTriageAction`.
enum TriageAction: Identifiable {
    case approve
    case merge
    case requestChanges
    case markReady
    case snooze(SnoozeDuration)
    case markSeen
    case dismiss
    case viewDiff
    case openInBrowser
    case openPreview
    case toggleMute

    var id: String { label }

    var label: String {
        switch self {
        case .approve:            return "Approve PR"
        case .merge:              return "Merge PR"
        case .requestChanges:     return "Request Changes"
        case .markReady:          return "Mark Ready for Review"
        case .snooze(let d):      return "Later — \(d.title)"
        case .markSeen:           return "Mark as Seen"
        case .dismiss:            return "Dismiss"
        case .viewDiff:           return "View Details"
        case .openInBrowser:      return "Open in Browser"
        case .openPreview:        return "Open Preview"
        case .toggleMute:         return "Mute / Move Up"
        }
    }

    var symbolName: String {
        switch self {
        case .approve:         return "checkmark.circle"
        case .merge:           return "arrow.triangle.merge"
        case .requestChanges:  return "text.bubble"
        case .markReady:       return "paperplane"
        case .snooze:          return "clock"
        case .markSeen:        return "eye"
        case .dismiss:         return "xmark"
        case .viewDiff:        return "rectangle.stack"
        case .openInBrowser:   return "safari"
        case .openPreview:     return "globe"
        case .toggleMute:      return "arrow.down.circle"
        }
    }

    /// Returns true if this action requires write-actions to be enabled.
    var requiresWriteActions: Bool {
        switch self {
        case .approve, .merge, .requestChanges, .markReady: return true
        default: return false
        }
    }
}

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
/// single-key verb dispatch, multi-select, PR peek, a per-row context
/// menu (right-click), and the undo toast stack.
///
/// Key bindings (user-configurable in Settings → Keyboard):
///   J / ↓  — next PR (default: j)
///   K / ↑  — previous PR (default: k)
///   Space  — peek: glance card + files (PRPeekView) (default: space)
///   ↵      — open selected PR in browser (works while peek is open too)
///   M      — merge (write-gated) (default: m)
///   F      — mark draft PR ready for review (write-gated, draft-only) (default: f)
///   R      — refresh (default: r)
///   E      — open preview (default: e; was p)
///   S      — postpone (uses the default duration set in Settings) (default: s)
///   N      — mark seen (default: n; was e)
///   X      — dismiss (default: x)
///   V      — toggle multi-select mode (default: v)
///   D      — toggle draft visibility (default: d)
///   Q      — toggle Inbox mute (default: q)
///   ⌘Z     — undo last action (default: z with ⌘)
///   right-click — full action menu (see `rowContextMenu`)
struct TriageDeckView: View {
    let prs: [PRSnapshot]
    /// Muted PRs for the Inbox tab. Empty on the For-me / Created tabs.
    var mutedPRs: [PRSnapshot] = []
    /// Whether the Inbox view is active (two role sections + Muted group).
    var inboxMode: Bool = false
    @ObservedObject var manager: PRManager
    @ObservedObject var settings: MainlineSettings

    @State private var selectedIndex: Int = 0
    /// Whether the peek overlay is open. The peek TARGET lives on `manager.peekPR`
    /// (so `MenuBarView` can present the card at the panel level and use the full
    /// popover height); this deck only reads/sets it. Set by both the Space key
    /// (focused row) and the row context menu (the right-clicked row), so the peek
    /// always matches the row the user acted on — not merely the keyboard-focused one.
    private var showPeek: Bool { manager.peekPR != nil }
    @State private var multiSelectMode: Bool = false
    @State private var selectedPRs: Set<String> = []   // nodeIds

    // Scroll-thrash guard: hover selection is suppressed briefly after a scroll
    // wheel event so that scrolling the list (which sweeps the stationary pointer
    // across many rows, each firing `.onHover`) doesn't cause the selection — and
    // its revealed action cluster — to jump around while you scroll.
    @State private var lastScrollAt: Date = .distantPast
    @State private var scrollMonitor: Any?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if inboxMode {
                // Inbox view: role sections ("Needs your review" / "Your PRs") +
                // a collapsed "Muted / low-priority" group at the bottom.
                if inboxSections.isEmpty && mutedPRs.isEmpty {
                    emptyState
                } else {
                    inboxList
                }
            } else {
                // Show "Queue clear" only when there is genuinely nothing to display —
                // no active PRs AND no Postponed/Done sections. Guarding on `prs` (the
                // active list) alone hid the Postponed and Done sections whenever the
                // active list was empty, so postponing everything in a scope left no way
                // to see or resume those PRs. `sections` already folds in Postponed/Done.
                if sections.isEmpty {
                    emptyState
                } else {
                    prList
                }
            }
        }
        // Neither the peek overlay nor the undo toast is rendered here — both are
        // presented at the PANEL level in `MenuBarView` (reading `manager.peekPR` /
        // `manager.undoEntries`) so they pin to the true bottom of the popover
        // instead of the bottom of this deck's (content-sized) bounds.
        //
        // Keyboard triage capture. A first-responder NSView that overrides keyDown
        // directly — reliable inside the MenuBarExtra popover regardless of how it
        // was opened, unlike a global/local NSEvent monitor which needs the app to
        // be active. `handleKeyDown` returns nil when it consumed the key.
        .background(
            KeyCaptureView(
                handler: { event in handleKeyDown(event) },
                onDismiss: { manager.peekPR = nil }
            )
        )
        .onAppear { installScrollMonitor() }
        .onDisappear { removeScrollMonitor() }
    }

    // MARK: - Scroll monitor (hover-thrash guard)

    /// Installs a local scroll-wheel monitor that timestamps the last scroll, so
    /// `.onHover` can ignore selection changes that fire merely because content
    /// scrolled under a stationary pointer. Local monitor → only this app's events.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            lastScrollAt = Date()
            return event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    /// True within a short window after the last scroll — used to gate hover
    /// selection so scrolling doesn't drag the highlight around.
    private var isScrolling: Bool {
        Date().timeIntervalSince(lastScrollAt) < 0.18
    }

    // MARK: - PR list

    /// PRs in the raw flat triage sort — Open/InReview/Approved above Draft, then
    /// most-recently-updated first. This is the WITHIN-GROUP ordering base only; it
    /// is NOT the keyboard index space. J/K navigation walks `orderedPRs` below,
    /// which follows the grouped display order so focus never crosses a group
    /// boundary in the wrong visual direction.
    private var triageSorted: [PRSnapshot] {
        prs.sorted(by: PRSnapshot.triageOrder)
    }

    /// The focusable actionability sections (Needs attention → Ready to merge →
    /// Waiting → Draft → …) in canonical display order, excluding the display-only
    /// Postponed and Done sections. Both `sections` (display) and `orderedPRs`
    /// (keyboard index space) build on this, so the two orderings never diverge.
    private var actionabilitySections: [(group: ActionGroup, prs: [PRSnapshot])] {
        let grouped = Dictionary(grouping: triageSorted, by: { groupFor($0) })
        return ActionGroup.allCases
            .filter { $0 != .postponed }
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { group -> (group: ActionGroup, prs: [PRSnapshot])? in
                guard let prs = grouped[group], !prs.isEmpty else { return nil }
                return (group, prs.sorted(by: PRSnapshot.triageOrder))
            }
    }

    /// The keyboard index space that J/K navigation walks. Flattens the focusable
    /// actionability sections IN DISPLAY ORDER so the flat index matches the on-
    /// screen top-to-bottom row order. (Previously this was a single flat
    /// `triageOrder` sort that ignored grouping — which put non-draft PRs above
    /// drafts in the index while the display rendered the draft-heavy "Needs
    /// attention" group first, so pressing J/K jumped focus into the group above.)
    private var orderedPRs: [PRSnapshot] {
        if inboxMode {
            // Inbox: keyboard index space is role-sections + (expanded) muted rows.
            var list = inboxOrderedPRs
            if settings.collapsedSections.contains(.muted) {
                list += mutedPRs.sorted(by: PRSnapshot.triageOrder)
            }
            return list
        }
        var list = actionabilitySections.flatMap { $0.prs }
        // Include Postponed rows in the keyboard/hover focus space ONLY while that
        // section is expanded (it is collapsed by default). Expanded ⇔ the section
        // is present in `collapsedSections` — `expansionBinding` inverts the default
        // for Postponed/Done. This lets J/K and hover focus postponed rows (and S
        // resume them) without ever focusing a row hidden in a collapsed section.
        // Done stays display-only (a finished PR has no triage verb).
        if settings.collapsedSections.contains(.postponed) {
            list += manager.postponedPRs.sorted(by: postponedWakeOrder)
        }
        return list
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
        var result = actionabilitySections

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

    // MARK: - Inbox sections

    /// The role-section + actionability structure for the Inbox view.
    /// Two outer role sections in canonical order (Needs-your-review first),
    /// each populated with `prs` matching that role and sorted by actionability.
    private var inboxSections: [(role: InboxRole, actionSections: [(group: ActionGroup, prs: [PRSnapshot])])] {
        let myLogin = settings.githubUsername
        let needsReview = prs.filter { $0.inboxRole(myLogin: myLogin) == .needsYourReview }
            .sorted(by: PRSnapshot.triageOrder)
        let yourPRs = prs.filter { $0.inboxRole(myLogin: myLogin) == .yourPRs }
            .sorted(by: PRSnapshot.triageOrder)

        var result: [(role: InboxRole, actionSections: [(group: ActionGroup, prs: [PRSnapshot])])] = []
        for (role, rolePRs) in [(InboxRole.yourPRs, yourPRs), (.needsYourReview, needsReview)] {
            guard !rolePRs.isEmpty else { continue }
            let grouped = Dictionary(grouping: rolePRs, by: { $0.actionGroup(splitDrafts: settings.splitDrafts) })
            let actionSections: [(group: ActionGroup, prs: [PRSnapshot])] = ActionGroup.allCases
                .filter { $0 != .postponed && $0 != .done && $0 != .muted }
                .sorted { $0.sortIndex < $1.sortIndex }
                .compactMap { group -> (group: ActionGroup, prs: [PRSnapshot])? in
                    guard let sectionPRs = grouped[group], !sectionPRs.isEmpty else { return nil }
                    return (group, sectionPRs)
                }
            if !actionSections.isEmpty {
                result.append((role: role, actionSections: actionSections))
            }
        }
        return result
    }

    /// All PRs in the Inbox view in display order (for keyboard index space).
    private var inboxOrderedPRs: [PRSnapshot] {
        inboxSections.flatMap { section in
            section.actionSections.flatMap { $0.prs }
        }
    }

    /// The Inbox list: role sections, then the shared Muted group.
    private var inboxList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(inboxSections, id: \.role.rawValue) { section in
                inboxRoleSectionHeader(for: section.role, prs: inboxRolePRs(for: section.role))
                ForEach(section.actionSections, id: \.group) { actionSection in
                    sectionView(
                        group: actionSection.group,
                        prs: actionSection.prs,
                        expansion: inboxExpansionBinding(for: section.role, group: actionSection.group)
                    )
                }
            }
            if !mutedPRs.isEmpty {
                mutedGroupView
            }
        }
    }

    private func inboxRolePRs(for role: InboxRole) -> [PRSnapshot] {
        let myLogin = settings.githubUsername
        return prs.filter { $0.inboxRole(myLogin: myLogin) == role }
    }

    @ViewBuilder
    private func inboxRoleSectionHeader(for role: InboxRole, prs rolePRs: [PRSnapshot]) -> some View {
        let title = role == .needsYourReview ? "Needs your review" : "Your PRs"
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            Text("\(rolePRs.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// The shared "Muted / low-priority (N)" group rendered at the bottom of the
    /// Inbox view. Collapsed by default (persisted via `.muted` in collapsedSections).
    @ViewBuilder
    private var mutedGroupView: some View {
        let expansion = expansionBinding(for: .muted)
        Button {
            expansion.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(ActionGroup.muted.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("\(mutedPRs.count)")
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
        .help(expansion.wrappedValue ? "Collapse muted PRs" : "Expand muted PRs")

        if expansion.wrappedValue {
            sectionRows(group: .muted, prs: mutedPRs.sorted(by: PRSnapshot.triageOrder))
        }
    }

    /// Ordering for the Postponed section: soonest wake first, then title.
    private func postponedWakeOrder(_ lhs: PRSnapshot, _ rhs: PRSnapshot) -> Bool {
        let lw = manager.snoozeStore.wakeTime(nodeId: lhs.nodeId) ?? .distantFuture
        let rw = manager.snoozeStore.wakeTime(nodeId: rhs.nodeId) ?? .distantFuture
        if lw != rw { return lw < rw }
        return lhs.title < rhs.title
    }

    /// The single main list: the keyboard-navigable deck grouped into
    /// collapsible actionability sections. Row focus indices map back into
    /// `orderedPRs`, which is itself flattened from these sections in display order,
    /// so J/K navigation follows the on-screen top-to-bottom row order.
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
                sectionView(group: section.group, prs: section.prs, expansion: expansionBinding(for: section.group))
            }
        }
    }

    /// Row layout metrics for the current density.
    private var metrics: RowMetrics {
        RowMetrics.forCompact(settings.compactRows)
    }

    @ViewBuilder
    private func sectionView(
        group: ActionGroup,
        prs sectionPRs: [PRSnapshot],
        expansion: Binding<Bool>
    ) -> some View {
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
            sectionRows(group: group, prs: sectionPRs)
        }
    }

    /// Renders a section's rows using a nodeId→index map computed ONCE (not per
    /// row via `flatIndex`). Deck rows are memoized via `memoizedDeckRow`.
    private func sectionRows(group: ActionGroup, prs sectionPRs: [PRSnapshot]) -> some View {
        let indexMap = orderedIndexByNodeId
        return ForEach(sectionPRs, id: \.nodeId) { pr in
            rowFor(group: group, pr: pr, index: indexMap[pr.nodeId] ?? 0)
            Divider().padding(.leading, metrics.dividerInset())
        }
    }

    @ViewBuilder
    private func rowFor(group: ActionGroup, pr: PRSnapshot, index: Int) -> some View {
        if group == .postponed {
            postponedRow(pr: pr, index: index)
        } else if group == .done {
            doneRow(pr: pr)
        } else {
            memoizedDeckRow(pr: pr, index: index)
        }
    }

    /// Index of a PR within the flat `orderedPRs` array (keyboard index space).
    private func flatIndex(of pr: PRSnapshot) -> Int {
        orderedPRs.firstIndex(where: { $0.nodeId == pr.nodeId }) ?? 0
    }

    /// Precomputed nodeId → keyboard-index map. Callers cache this in a local ONCE
    /// per section render instead of calling `flatIndex(of:)` per row, which
    /// recomputed the entire `orderedPRs` list for every row — O(n²) per render and
    /// a major scroll/highlight cost with a large PR list.
    private var orderedIndexByNodeId: [String: Int] {
        var map: [String: Int] = [:]
        let ordered = orderedPRs
        map.reserveCapacity(ordered.count)
        for (i, pr) in ordered.enumerated() { map[pr.nodeId] = i }
        return map
    }

    /// Wraps `deckRow` in an `.equatable()` memoization shell keyed on the value
    /// inputs that affect a row's appearance. SwiftUI then skips re-rendering rows
    /// whose key is unchanged, so moving the highlight (J/K or hover) re-renders
    /// only the two affected rows instead of the entire non-lazy VStack.
    private func memoizedDeckRow(pr: PRSnapshot, index: Int) -> some View {
        EquatableRow(key: DeckRowKey(
            pr: pr,
            index: index,
            isFocused: index == selectedIndex,
            isSelected: selectedPRs.contains(pr.nodeId),
            isUnread: manager.unreadPRIds.contains(pr.nodeId),
            reviewSourceVisible: settings.selectedTab == .forMe,
            myLogin: settings.githubUsername,
            writeActionsEnabled: settings.writeActionsEnabled,
            previewEnabled: settings.vercelPreviewEnabled,
            showPeek: showPeek,
            compact: settings.compactRows
        )) {
            deckRow(pr: pr, index: index)
        }
        .equatable()
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
        // Postponed, Done, and Muted all INVERT the default: they are COLLAPSED by
        // default, and the `collapsedSections` set instead records that the user
        // explicitly EXPANDED them (so the choice persists once toggled). Every other
        // group is expanded by default and the set records collapse.
        if group == .postponed || group == .done || group == .muted {
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

    /// Collapse state for an Inbox action-group section, scoped to its `InboxRole`.
    ///
    /// The Inbox renders the same `ActionGroup` (e.g. `.waiting`) once under "Your
    /// PRs" and once under "Needs your review". Keying purely by `ActionGroup` — as
    /// `expansionBinding(for:)` does — made both collapse together. This scopes the
    /// key by role via a composite `"inbox:<role>:<group>"` string persisted in the
    /// SAME `collapsedSectionsRaw` store (no new UserDefaults key). Those composite
    /// strings don't decode to any `ActionGroup`, so the non-Inbox
    /// `collapsedSections` accessor silently ignores them. Expanded by default; the
    /// store records an explicit collapse — matching the normal-group semantics.
    private func inboxExpansionBinding(for role: InboxRole, group: ActionGroup) -> Binding<Bool> {
        let key = "inbox:\(role.rawValue):\(group.rawValue)"
        return Binding(
            get: { !settings.collapsedSectionsRaw.contains(key) },
            set: { expanded in
                var raw = settings.collapsedSectionsRaw
                if expanded {
                    raw.removeAll { $0 == key }
                } else if !raw.contains(key) {
                    raw.append(key)
                }
                settings.collapsedSectionsRaw = raw
            }
        )
    }

    private func deckRow(pr: PRSnapshot, index: Int) -> some View {
        let isFocused = index == selectedIndex
        let isSelected = selectedPRs.contains(pr.nodeId)
        let isDraft = pr.isDraft
        // The trailing "Later"/"Merge" cluster reveals on the SELECTED row. Hover and
        // keyboard drive one selection (see `.onHover` below), so the cluster follows
        // whichever row the pointer or the keyboard last landed on.
        let isHovered = isFocused
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
                        Text(verbatim: pr.author.isEmpty
                             ? "\(pr.repoFullName) #\(pr.number)"
                             : "\(pr.repoFullName) #\(pr.number) · \(pr.author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isDraft {
                            DraftBadge()
                        }
                        if settings.selectedTab == .forMe {
                            ReviewSourceBadge(pr: pr, myLogin: settings.githubUsername)
                        }
                        PreviewBadge(pr: pr, settings: settings)
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
            // Hover SELECTS the row — mouse and keyboard share one selection
            // (`selectedIndex`), so hover-then-Space/Enter acts on the pointed row.
            // Sticky: selection stays put when the cursor leaves (no revert to a
            // pre-hover row — that would read as a glitch). Frozen while the peek is
            // open so stray movement over the dimmed rows can't shift selection.
            // No animation here on purpose: the highlight + revealed actions switch
            // instantly, which removes the cross-row hover "blink".
            .onHover { hovering in
                guard hovering, !showPeek, !isScrolling else { return }
                selectedIndex = index
            }
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, m.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? Color.accentColor.opacity(0.22) : .clear)
            // Focus / multi-select indication rendered as a leading accent bar in
            // the row's leading padding, so it never consumes a layout column and
            // the shared LeadingColumn stays aligned with the Needs-a-Human rows.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected || isFocused ? Color.accentColor : Color.clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowContextMenu(for: pr) }
    }

    /// Native right-click action menu for a PR row — the discoverable home for
    /// every triage verb (replaces the old ⌘K command palette). Write actions are
    /// disabled while `writeActionsEnabled` is off. Dispatches through the same
    /// `handleTriageAction` path as the single-key verbs.
    @ViewBuilder
    private func rowContextMenu(for pr: PRSnapshot) -> some View {
        let writeOff = !settings.writeActionsEnabled
        Button { handleTriageAction(.approve, on: pr) } label: {
            Label("Approve PR", systemImage: "checkmark.circle")
        }
        .disabled(writeOff)
        // Merge is always LISTED for discoverability, but only ENABLED when the PR
        // can actually be merged (approved, clean, green CI, open) — the same
        // `readyToMerge` gate as the inline Merge button — or when write actions are
        // off. A disabled item can't be clicked, so the reason for an unmergeable PR
        // is surfaced instead via the M-key toast (see `handleKeyDown`).
        Button { handleTriageAction(.merge, on: pr) } label: {
            Label("Merge PR", systemImage: "arrow.triangle.merge")
        }
        .disabled(writeOff || !pr.readyToMerge)
        Button { handleTriageAction(.requestChanges, on: pr) } label: {
            Label("Request Changes", systemImage: "text.bubble")
        }
        .disabled(writeOff)
        if pr.isDraft {
            Button { handleTriageAction(.markReady, on: pr) } label: {
                Label("Mark Ready for Review", systemImage: "paperplane")
            }
            .disabled(writeOff)
        }

        Divider()

        Menu {
            ForEach(SnoozeDuration.allCases) { duration in
                Button(duration.title) { handleTriageAction(.snooze(duration), on: pr) }
            }
        } label: {
            Label("Later", systemImage: "clock")
        }
        Button { handleTriageAction(.markSeen, on: pr) } label: {
            Label("Mark as Seen", systemImage: "eye")
        }
        Button { handleTriageAction(.dismiss, on: pr) } label: {
            Label("Dismiss", systemImage: "xmark")
        }
        if inboxMode {
            let muted = manager.isInboxMuted(pr)
            Button { handleTriageAction(.toggleMute, on: pr) } label: {
                Label(muted ? "Move Up (Un-mute)" : "Mute / Low-priority",
                      systemImage: muted ? "arrow.up.circle" : "arrow.down.circle")
            }
        }

        Divider()

        Button { handleTriageAction(.viewDiff, on: pr) } label: {
            Label("View Details", systemImage: "rectangle.stack")
        }
        Button { handleTriageAction(.openInBrowser, on: pr) } label: {
            Label(openActionLabel, systemImage: openActionSymbol)
        }
        if pr.vercelPreviewUrl != nil {
            Button { handleTriageAction(.openPreview, on: pr) } label: {
                Label("Open Preview", systemImage: "globe")
            }
        }
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
    private func postponedRow(pr: PRSnapshot, index: Int) -> some View {
        let m = metrics
        let isFocused = index == selectedIndex
        let wake = manager.snoozeStore.wakeTime(nodeId: pr.nodeId)
        return Button {
            handleRowClick(pr: pr, index: index)
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
                        Text(verbatim: pr.author.isEmpty
                             ? "\(pr.repoFullName) #\(pr.number)"
                             : "\(pr.repoFullName) #\(pr.number) · \(pr.author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
            // Hover selects the row — shared with keyboard focus — so hover-then-S
            // resumes the pointed row, matching the deck rows. Frozen while peeking.
            .onHover { hovering in
                guard hovering, !showPeek, !isScrolling else { return }
                selectedIndex = index
            }
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, m.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? Color.accentColor.opacity(0.22) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isFocused ? Color.accentColor : Color.clear)
                    .frame(width: 3)
            }
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
            manager.openPR(pr)
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
                        Text(verbatim: pr.author.isEmpty
                             ? "\(pr.repoFullName) #\(pr.number)"
                             : "\(pr.repoFullName) #\(pr.number) · \(pr.author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
            manager.openPR(pr)
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

    // MARK: - Keyboard triage

    /// Returns true when the event matches the user-configured binding for the
    /// given shortcut — both the base key (ignoring modifiers) AND the masked
    /// modifier set must match. A bare binding (empty modifier set) matches
    /// only when no relevant modifiers are held; a modified binding matches
    /// only with exactly those modifiers held.
    private func shortcutMatches(_ shortcut: InAppShortcut, event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let binding = settings.shortcutBindings.binding(for: shortcut)
        guard !binding.key.isEmpty, chars == binding.key else { return false }
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(ShortcutBinding.relevantModifierMask)
        return mods == binding.modifierFlags
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Return opens the selected PR in the browser — regardless of whether the
        // peek card is open (focusedPR stays in sync with the card as you step).
        if event.keyCode == 36 {   // Return
            if let pr = focusedPR { handleTriageAction(.openInBrowser, on: pr) }
            return nil
        }

        // While the peek overlay is showing: J/K/arrows step through PRs and update
        // the card in place; Space (the key that opened it) or Esc closes it. Other
        // keys are swallowed so deck verbs don't fire behind the card.
        if showPeek {
            if shortcutMatches(.navigateDown, event: event) || chars == "\u{F701}" {
                moveDown(); manager.peekPR = focusedPR; return nil
            }
            if shortcutMatches(.navigateUp, event: event) || chars == "\u{F700}" {
                moveUp(); manager.peekPR = focusedPR; return nil
            }
            if shortcutMatches(.peek, event: event) {   // configured peek key closes peek
                manager.peekPR = nil; return nil
            }
            if shortcutMatches(.openPreview, event: event) {
                if let pr = focusedPR { openPreview(pr) }
                return nil
            }
            if event.keyCode == 53 { manager.peekPR = nil; return nil }   // Esc
            return event
        }

        // Navigation (also accepts raw arrow keys).
        // Arrow-key fallbacks apply only when no relevant modifiers are held
        // (e.g. ⌘+Arrow must not trigger navigation).
        let noRelevantMods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(ShortcutBinding.relevantModifierMask)
            .isEmpty
        if shortcutMatches(.navigateDown, event: event) || (chars == "\u{F701}" && noRelevantMods) {
            moveDown()
            return nil
        }
        if shortcutMatches(.navigateUp, event: event) || (chars == "\u{F700}" && noRelevantMods) {
            moveUp()
            return nil
        }

        // Peek (glance + files). Modifier check is inside shortcutMatches.
        if shortcutMatches(.peek, event: event) {
            if let pr = focusedPR {
                manager.peekPR = pr
                TelemetryService.shared.recordTriageInteraction("diff_preview")
            }
            return nil
        }

        // Undo — default ⌘Z; modifier requirement lives in the stored binding.
        if shortcutMatches(.undo, event: event) {
            undoLast()
            TelemetryService.shared.recordTriageInteraction("undo")
            return nil
        }

        // Write verb (gated by writeActionsEnabled). Approve and Request Changes
        // remain available via the row context menu only. Merge only PERFORMS when
        // the PR is actually mergeable (`readyToMerge` — same condition that shows
        // the inline Merge button); on any other PR, instead of a silent no-op we
        // surface a toast explaining why it can't be merged, so M never feels dead.
        if shortcutMatches(.merge, event: event) {
            if let pr = focusedPR {
                if pr.readyToMerge {
                    dispatchVerb(.merge(pr))
                } else if let reason = pr.mergeBlockReason {
                    manager.showInfoToast("Can't merge: \(reason)", symbol: "arrow.triangle.merge")
                }
            }
            return nil
        }

        // Mark Ready for Review — draft-only; silent no-op on non-draft PRs.
        if shortcutMatches(.markReady, event: event) {
            if let pr = focusedPR, pr.isDraft { handleTriageAction(.markReady, on: pr) }
            return nil
        }

        // Refresh the PR list. Works whether or not a row is focused.
        if shortcutMatches(.refresh, event: event) {
            Task { await manager.triggerSingleRefresh() }
            TelemetryService.shared.recordTriageInteraction("refresh")
            return nil
        }

        // Open the PR's Vercel preview deployment. Silent no-op when no preview
        // was detected for the focused row.
        if shortcutMatches(.openPreview, event: event) {
            if let pr = focusedPR { openPreview(pr) }
            return nil
        }

        // Quick "Later" — postpone with the user's configured default duration.
        // On an already-postponed row, the same key resumes it.
        if shortcutMatches(.snooze, event: event) {
            if let pr = focusedPR {
                if manager.snoozeStore.isSnoozed(pr) {
                    resume(pr)
                } else {
                    postpone(pr, for: settings.defaultSnoozeDuration)
                }
            }
            return nil
        }

        // Mark seen.
        if shortcutMatches(.markSeen, event: event) {
            if let pr = focusedPR {
                Task { await manager.performAction(.markSeen(pr)) }
                pushUndo(label: "Marked seen: \(pr.title)", pr: pr) {}
            }
            return nil
        }

        // Dismiss.
        if shortcutMatches(.dismiss, event: event) {
            if let pr = focusedPR {
                Task { await manager.performAction(.dismiss(pr)) }
                pushUndo(label: "Dismissed \(pr.title)", pr: pr) {}
            }
            return nil
        }

        // Multi-select toggle.
        if shortcutMatches(.multiSelectToggle, event: event) {
            multiSelectMode.toggle()
            TelemetryService.shared.recordTriageInteraction("multi_select_toggle")
            return nil
        }

        // Toggle draft visibility.
        if shortcutMatches(.toggleDrafts, event: event) {
            settings.showDrafts.toggle()
            TelemetryService.shared.recordTriageInteraction("toggle_drafts")
            return nil
        }

        // Toggle Inbox mute / move-up on the focused PR.
        if shortcutMatches(.toggleMute, event: event) {
            if let pr = focusedPR { handleTriageAction(.toggleMute, on: pr) }
            return nil
        }

        return event
    }

    private func moveDown() {
        let count = orderedPRs.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + 1, count - 1)
    }

    private func moveUp() {
        guard !orderedPRs.isEmpty else { return }
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

    // MARK: - Triage action from context menu

    /// Context-menu label for the open action, tracking the configured target so
    /// right-click reads "Open in Linear" instead of "Open in Browser" under Linear.
    private var openActionLabel: String {
        settings.prOpenTarget == .linear ? "Open in Linear" : "Open in Browser"
    }

    /// Matching SF Symbol for the open action's target.
    private var openActionSymbol: String {
        settings.prOpenTarget == .linear ? "arrow.up.forward.app" : "safari"
    }

    private func handleTriageAction(_ action: TriageAction, on pr: PRSnapshot) {
        switch action {
        case .approve:
            dispatchVerb(.approve(pr))
        case .merge:
            dispatchVerb(.merge(pr))
        case .requestChanges:
            dispatchVerb(.requestChanges(pr))
        case .markReady:
            markReady(pr)
        case .snooze(let duration):
            postpone(pr, for: duration)
        case .markSeen:
            Task { await manager.performAction(.markSeen(pr)) }
            pushUndo(label: "Marked seen: \(pr.title)", pr: pr) {}
        case .dismiss:
            Task { await manager.performAction(.dismiss(pr)) }
            pushUndo(label: "Dismissed \(pr.title)", pr: pr) {}
        case .viewDiff:
            manager.peekPR = pr
            TelemetryService.shared.recordTriageInteraction("diff_preview")
        case .openInBrowser:
            manager.openPR(pr)
        case .openPreview:
            openPreview(pr)
        case .toggleMute:
            let prevOverride = manager.inboxMuteOverride(for: pr)
            let nowMuted = manager.toggleInboxMute(pr)
            TelemetryService.shared.recordTriageInteraction(nowMuted ? "inbox_mute" : "inbox_unmute")
            pushUndo(label: nowMuted ? "Muted: \(pr.title)" : "Moved up: \(pr.title)", pr: pr) {
                manager.setInboxMuteOverride(prevOverride, for: pr)
            }
        }
    }

    /// Opens the PR's Vercel preview deployment in the browser. Silent no-op when
    /// the PR has no detected preview URL — matches how M/S no-op when inapplicable.
    private func openPreview(_ pr: PRSnapshot) {
        guard let preview = pr.vercelPreviewUrl, let url = URL(string: preview) else { return }
        TelemetryService.shared.recordTriageInteraction("open_preview")
        NSWorkspace.shared.open(url)
    }

    /// Marks a draft PR as ready for review — fires immediately (no NSAlert confirm),
    /// gated by `settings.writeActionsEnabled` and `pr.isDraft`.
    /// Shows the write-actions disabled guidance alert when write actions are off.
    /// Shows a plain confirmation toast (non-undoable — no inverse convert-to-draft).
    private func markReady(_ pr: PRSnapshot) {
        guard pr.isDraft else { return }
        guard settings.writeActionsEnabled else {
            let alert = NSAlert()
            alert.messageText = "Write Actions Disabled"
            alert.informativeText = "Enable \"Write Actions\" in Settings to use approve, merge, request-changes, and mark-ready."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        Task { await manager.performAction(.markReady(pr)) }
        // Plain confirmation toast — empty undo closure (no convert-back-to-draft).
        pushUndo(label: "Marked ready: \(pr.title)", pr: pr) {}
    }

    // MARK: - Undo

    private func pushUndo(label: String, pr: PRSnapshot, undoFn: @escaping () -> Void) {
        let entry = UndoEntry(label: label, pr: pr, undo: undoFn)
        withAnimation { manager.undoEntries.append(entry) }
        // Auto-dismiss after 8s
        let id = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            withAnimation { manager.undoEntries.removeAll { $0.id == id } }
        }
    }

    private func undoLast() {
        guard let last = manager.undoEntries.last else { return }
        last.undo()
        withAnimation { manager.undoEntries.removeLast() }
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
/// the `M` keyboard verb / row context menu (`dispatchVerb(.merge)` →
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

// MARK: - Deck row memoization

/// Value bundle of everything that changes a deck row's rendered appearance.
/// Used as the Equatable key for `EquatableRow` so unchanged rows skip
/// re-rendering when the highlight moves. Settings-derived values are captured
/// as plain values (not read live inside the row) so a change to any of them
/// flips the key and re-renders the row.
private struct DeckRowKey: Equatable {
    let pr: PRSnapshot
    /// The row's position in the flattened `orderedPRs` index space. Part of the
    /// key so a row whose position SHIFTS (poll reorder, section expand/collapse,
    /// snooze/dismiss above it) re-renders and its `.onHover { selectedIndex = index }`
    /// closure recaptures the fresh index. Omitting it let a memoized row keep a
    /// stale captured index, so hovering it highlighted a DIFFERENT row. During pure
    /// hover / J-K nav the composition is stable, so this never triggers extra
    /// re-renders — only real reorders (which must re-render anyway) do.
    let index: Int
    let isFocused: Bool
    let isSelected: Bool
    let isUnread: Bool
    let reviewSourceVisible: Bool
    let myLogin: String
    let writeActionsEnabled: Bool
    let previewEnabled: Bool
    let showPeek: Bool
    let compact: Bool
}

/// Memoizing wrapper: re-evaluates `content()` only when `key` changes. Paired
/// with `.equatable()` at the call site so SwiftUI uses `==` to skip stable rows.
private struct EquatableRow<Content: View>: View, Equatable {
    let key: DeckRowKey
    @ViewBuilder var content: () -> Content
    static func == (lhs: EquatableRow, rhs: EquatableRow) -> Bool { lhs.key == rhs.key }
    var body: some View { content() }
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
            // De-emphasized: just the icon + count (no "unresolved" word, no amber
            // pill) so open threads read as a quiet comment indicator.
            HStack(spacing: 2) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.caption2)
                Text("\(pr.unresolvedThreadCount)")
                    .font(.caption2)
            }
            .lineLimit(1)
            .foregroundStyle(.secondary)
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

// MARK: - PreviewBadge

/// Compact indicator shown on the repo/#number metadata line when a Vercel
/// preview deployment was detected for the PR. Cyan globe + "Preview" label,
/// styled like the other row badges. Its presence is the affordance for the
/// open-preview verb; the tooltip renders the live binding glyph so it stays
/// accurate when the user rebinds the shortcut. Hidden entirely when no preview
/// exists.
struct PreviewBadge: View {
    let pr: PRSnapshot
    @ObservedObject var settings: MainlineSettings

    var body: some View {
        if pr.vercelPreviewUrl != nil {
            let glyph = MainlineSettings.glyph(for: settings.shortcutBindings.binding(for: .openPreview))
            Image(systemName: "globe")
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .systemTeal))
                .help("Vercel preview available — press \(glyph) to open")
                .accessibilityLabel("Preview deployment available")
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

// MARK: - KeyCaptureView

/// A zero-size `NSView` that takes first responder and handles `keyDown` directly,
/// giving the triage deck reliable keyboard capture inside the MenuBarExtra popover.
///
/// Why not an `NSEvent` local monitor: a local monitor only fires while the app is
/// active, and clicking the menu bar icon does not activate an accessory app — so
/// J/K/arrows silently did nothing on click-open. A first-responder view receives
/// `keyDown` whenever its window is key (which the popover is, since it hosts
/// interactive controls), independent of app-active state.
///
/// `handler` returns nil when it consumed the key (so it is not passed to `super`).
/// It is refreshed every SwiftUI update via `updateNSView`, so it never captures
/// stale `@State`.
private struct KeyCaptureView: NSViewRepresentable {
    let handler: (NSEvent) -> NSEvent?
    /// Called when the popover window resigns key — i.e. the menu bar popover was
    /// closed. Used to dismiss transient overlays (the peek card) so they aren't
    /// still open when the popover is reopened.
    var onDismiss: (() -> Void)? = nil

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handler = handler
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.handler = handler
        nsView.onDismiss = onDismiss
        nsView.reassertFocusIfIdle()
    }

    final class KeyView: NSView {
        var handler: ((NSEvent) -> NSEvent?)?
        var onDismiss: (() -> Void)?
        private var resignObserver: NSObjectProtocol?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeResignKey()
            guard window != nil else { return }
            takeFocus(attempt: 0)
        }

        /// Fire `onDismiss` when this view's window resigns key (popover closed).
        private func observeResignKey() {
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            guard let window else { return }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onDismiss?()
            }
        }

        deinit {
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }

        /// Reclaim first responder only when nothing meaningful holds it (the window
        /// or its contentView) — so we don't steal focus from a real control, but we
        /// do recover if SwiftUI reset the responder chain on a re-render. There are
        /// no text fields in the deck, so this is safe.
        func reassertFocusIfIdle() {
            guard let window else { return }
            let fr = window.firstResponder
            if fr !== self && (fr == nil || fr === window || fr === window.contentView) {
                window.makeFirstResponder(self)
            }
        }

        /// Claim first responder so keyDown routes here. Retry briefly because the
        /// popover window may not be key in the first runloop tick after it opens.
        private func takeFocus(attempt: Int) {
            guard let window else { return }
            window.makeFirstResponder(self)
            if window.firstResponder !== self, attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.takeFocus(attempt: attempt + 1)
                }
            }
        }

        override func keyDown(with event: NSEvent) {
            // handler returns nil == consumed (e.g. an overlay handled it); non-nil
            // == not consumed.
            if let handler, handler(event) == nil { return }
            // Esc that no overlay consumed dismisses the popover. This view is the
            // popover's first responder (so it can capture J/K/etc.), which otherwise
            // swallows the popover's built-in Esc-to-close — a plain NSView's keyDown
            // doesn't route Esc to cancelOperation, so handle it explicitly here.
            if event.keyCode == 53 {   // Esc
                window?.close()
                return
            }
            super.keyDown(with: event)
        }
    }
}
