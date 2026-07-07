import SwiftUI
import AppKit

// MARK: - RowMetrics

/// Shared layout metrics for PR rows, driven by `settings.compactRows`. Used by
/// both `TriageDeckView` deck rows and `NeedsHumanView` rows so the two lists
/// stay visually consistent at either density.
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

    /// Fixed width of the leading UNREAD-DOT slot, reserved on EVERY PR row (deck
    /// rows AND Needs-a-Human rows) whether or not an unread dot is shown, so the
    /// status icon that follows it starts at the same x in every section. The
    /// unread dot itself is 7pt; the slot is a touch wider to give the dot breathing
    /// room and keep the icon column stable. Shared by both row views so they can't
    /// drift.
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
        sectionHeaderTopPadding: 4,
        sectionHeaderBottomPadding: 2,
        unreadDotSlotWidth: 10
    )

    static let comfortable = RowMetrics(
        titleLineLimit: 2,
        rowVerticalPadding: 6,
        titleMetadataSpacing: 2,
        leadingIconSize: 20,
        rowHStackSpacing: 8,
        sectionHeaderTopPadding: 8,
        sectionHeaderBottomPadding: 2,
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

/// The single, shared leading structure for EVERY PR row — the triage deck rows
/// and the Needs-a-Human rows both compose it so their unread-dot slot and status
/// icon (and therefore their titles) line up in one column at both densities.
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
    @State private var showDiff: Bool = false
    @State private var showCommandPalette: Bool = false
    @State private var multiSelectMode: Bool = false
    @State private var selectedPRs: Set<String> = []   // nodeIds
    @State private var undoEntries: [UndoEntry] = []
    @State private var confirmingAction: WriteAction? = nil
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
        .confirmationDialog(
            confirmDialogTitle,
            isPresented: Binding(get: { confirmingAction != nil }, set: { if !$0 { confirmingAction = nil } }),
            titleVisibility: .visible
        ) {
            Button("Confirm") {
                if let action = confirmingAction {
                    Task { await manager.performAction(action) }
                    confirmingAction = nil
                }
            }
            Button("Cancel", role: .cancel) {
                confirmingAction = nil
            }
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
    /// Needs attention → Ready to merge → Waiting → Draft → Merged → Closed.
    private var sections: [(group: ActionGroup, prs: [PRSnapshot])] {
        let grouped = Dictionary(grouping: orderedPRs, by: { groupFor($0) })
        return ActionGroup.allCases
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { group in
                guard let prs = grouped[group], !prs.isEmpty else { return nil }
                return (group, prs.sorted(by: PRSnapshot.triageOrder))
            }
    }

    /// The single main list: the keyboard-navigable deck grouped into
    /// collapsible actionability sections. Row focus indices map back into the flat
    /// `orderedPRs` array so J/K navigation is unaffected by grouping.
    private var prList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.group) { section in
                    sectionView(group: section.group, prs: section.prs)
                }
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
            withAnimation(.easeInOut(duration: 0.15)) { expansion.wrappedValue.toggle() }
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
                deckRow(pr: pr, index: flatIndex(of: pr))
                Divider().padding(.leading, metrics.dividerInset())
            }
        }
    }

    /// Index of a PR within the flat `orderedPRs` array (keyboard index space).
    private func flatIndex(of pr: PRSnapshot) -> Int {
        orderedPRs.firstIndex(where: { $0.nodeId == pr.nodeId }) ?? 0
    }

    /// Collapse state persisted to MainlineSettings, keyed by `ActionGroup`.
    private func expansionBinding(for group: ActionGroup) -> Binding<Bool> {
        Binding(
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
                    ciIcon(for: pr.ciStatus)
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

                // Inline Merge — shown only on ready-to-merge rows. Separate hit
                // area (borderless button) so it never triggers the row's
                // click-to-open; routes through the SAME confirm + performAction
                // path as the M verb.
                if pr.readyToMerge {
                    Spacer(minLength: 4)
                    MergeButton(
                        writeActionsEnabled: settings.writeActionsEnabled,
                        onMerge: { dispatchVerb(.merge(pr)) }
                    )
                }
            }
            // Drafts read as lower-priority: mute the whole row while keeping
            // it fully clickable/openable.
            .opacity(isDraft ? 0.6 : 1.0)
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
            if let pr = focusedPR {
                Task { await manager.performAction(.snooze(pr, until: Date().addingTimeInterval(3600))) }
                pushUndo(label: "Snoozed \(pr.title)", pr: pr) {}
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
        // Require confirmation for write actions
        confirmingAction = action
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
        case .snooze1h:
            Task { await manager.performAction(.snooze(pr, until: Date().addingTimeInterval(3600))) }
            pushUndo(label: "Snoozed \(pr.title)", pr: pr) {}
        case .snooze24h:
            Task { await manager.performAction(.snooze(pr, until: Date().addingTimeInterval(86400))) }
            pushUndo(label: "Snoozed \(pr.title) 24h", pr: pr) {}
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

    // MARK: - Confirmation dialog title

    private var confirmDialogTitle: String {
        guard let action = confirmingAction else { return "Confirm Action" }
        switch action {
        case .approve(let pr): return "Approve \"\(pr.title)\"?"
        case .merge(let pr):   return "Merge \"\(pr.title)\"?"
        case .requestChanges(let pr): return "Request changes on \"\(pr.title)\"?"
        default: return "Confirm Action"
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
/// ready-to-merge PR row (deck rows and Needs-a-Human rows). It has its own
/// borderless hit area so a tap never triggers the row's click-to-open; the
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

// MARK: - DraftBadge

/// Compact gray/secondary pill marking a PR as a draft. Rendered on the
/// repo/#number metadata line alongside the trust/feedback/trigger tags, using
/// the same visual style so drafts are obvious while scrolling. Shared by the
/// triage deck rows and the Needs-a-Human rows.
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
