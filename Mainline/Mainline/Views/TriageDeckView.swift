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
                        isPresented: $showCommandPalette
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

    private var prList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(prs.enumerated()), id: \.element.nodeId) { index, pr in
                    deckRow(pr: pr, index: index)
                    Divider().padding(.leading, 36)
                }
            }
        }
    }

    private func deckRow(pr: PRSnapshot, index: Int) -> some View {
        let isFocused = index == selectedIndex
        let isSelected = selectedPRs.contains(pr.nodeId)
        return Button {
            selectedIndex = index
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text("\(pr.repoFullName) #\(pr.number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TrustBadgeView(tier: manager.trustLedger.tier(for: pr.author))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? Color.accentColor.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        guard selectedIndex < prs.count else { return nil }
        return prs[selectedIndex]
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
