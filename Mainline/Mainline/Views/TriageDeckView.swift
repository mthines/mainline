import SwiftUI
import AppKit

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

    /// Maps a canonical `classifiedState` to the state used for DISPLAY grouping.
    /// `.inReview` folds into `.open` so both render under one "Open" section; this
    /// is a display-only mapping and does NOT change `classifiedState` semantics
    /// (the classifier / trust / needs-human logic keeps using the real state).
    private func displayState(_ state: PRState) -> PRState {
        state == .inReview ? .open : state
    }

    /// Grouped sections in canonical state order, excluding empty ones. `.inReview`
    /// PRs are folded into the "Open" section (see `displayState`); the "Open"
    /// header count therefore equals open + in-review PRs combined.
    private var sections: [(state: PRState, prs: [PRSnapshot])] {
        let grouped = Dictionary(grouping: orderedPRs, by: { displayState($0.classifiedState) })
        return PRState.allCases
            .filter { $0 != .inReview }   // never render In Review as its own section
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { state in
                guard let prs = grouped[state], !prs.isEmpty else { return nil }
                return (state, prs.sorted(by: PRSnapshot.triageOrder))
            }
    }

    /// The single main list: the keyboard-navigable deck grouped into
    /// collapsible per-state sections. Row focus indices map back into the flat
    /// `orderedPRs` array so J/K navigation is unaffected by grouping.
    private var prList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.state) { section in
                    sectionView(state: section.state, prs: section.prs)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(state: PRState, prs sectionPRs: [PRSnapshot]) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: state)) {
            ForEach(sectionPRs, id: \.nodeId) { pr in
                deckRow(pr: pr, index: flatIndex(of: pr))
                Divider().padding(.leading, 36)
            }
        } label: {
            HStack(spacing: 6) {
                Text(state.title)
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
            }
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// Index of a PR within the flat `orderedPRs` array (keyboard index space).
    private func flatIndex(of pr: PRSnapshot) -> Int {
        orderedPRs.firstIndex(where: { $0.nodeId == pr.nodeId }) ?? 0
    }

    /// Collapse state persisted to MainlineSettings.
    private func expansionBinding(for state: PRState) -> Binding<Bool> {
        Binding(
            get: { !settings.collapsedSections.contains(state) },
            set: { expanded in
                var collapsed = settings.collapsedSections
                if expanded { collapsed.remove(state) } else { collapsed.insert(state) }
                settings.collapsedSections = collapsed
            }
        )
    }

    private func deckRow(pr: PRSnapshot, index: Int) -> some View {
        let isFocused = index == selectedIndex
        let isSelected = selectedPRs.contains(pr.nodeId)
        let isDraft = pr.classifiedState == .draft
        return Button {
            handleRowClick(pr: pr, index: index)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // Selection / focus indicator
                ZStack {
                    if isSelected {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    } else if isFocused {
                        Circle().fill(Color.accentColor.opacity(0.4)).frame(width: 8, height: 8)
                    } else {
                        Circle().fill(Color.clear).frame(width: 8, height: 8)
                    }
                }
                .frame(width: 20, height: 20, alignment: .center)

                if manager.unreadPRIds.contains(pr.nodeId) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                        .accessibilityLabel("Unread")
                }

                ciIcon(for: pr.ciStatus)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title)
                        .font(.callout)
                        .lineLimit(2)
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
            }
            // Drafts read as lower-priority: mute the whole row while keeping
            // it fully clickable/openable.
            .opacity(isDraft ? 0.6 : 1.0)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? Color.accentColor.opacity(0.08) : .clear)
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
///   2. else if review activity exists — `reviewState == .changesRequested`
///      (reviews present but no aggregate decision) OR `commentCount > 0` →
///      a subtle secondary comment badge (bubble icon + count, count omitted
///      when 0).
///   3. else → nothing.
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
