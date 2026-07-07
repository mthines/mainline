import SwiftUI

// MARK: - TriageAction

/// All actions available for a focused PR in the triage deck.
enum TriageAction: CaseIterable, Identifiable {
    case approve
    case merge
    case requestChanges
    case snooze(SnoozeDuration)
    case markSeen
    case dismiss
    case viewDiff
    case openInBrowser

    /// One palette entry per `SnoozeDuration`, plus the fixed non-snooze actions.
    static var allCases: [TriageAction] {
        [.approve, .merge, .requestChanges]
            + SnoozeDuration.allCases.map { TriageAction.snooze($0) }
            + [.markSeen, .dismiss, .viewDiff, .openInBrowser]
    }

    var id: String { label }

    var label: String {
        switch self {
        case .approve:            return "Approve PR"
        case .merge:              return "Merge PR"
        case .requestChanges:     return "Request Changes"
        case .snooze(let d):      return "Later — \(d.title)"
        case .markSeen:           return "Mark as Seen"
        case .dismiss:            return "Dismiss"
        case .viewDiff:           return "View Diff (Space)"
        case .openInBrowser:      return "Open in Browser"
        }
    }

    var symbolName: String {
        switch self {
        case .approve:         return "checkmark.circle"
        case .merge:           return "arrow.triangle.merge"
        case .requestChanges:  return "text.bubble"
        case .snooze:          return "clock"
        case .markSeen:        return "eye"
        case .dismiss:         return "xmark"
        case .viewDiff:        return "doc.plaintext"
        case .openInBrowser:   return "safari"
        }
    }

    /// Returns true if this action requires write-actions to be enabled.
    var requiresWriteActions: Bool {
        switch self {
        case .approve, .merge, .requestChanges: return true
        default: return false
        }
    }
}

// MARK: - CommandPaletteView

/// Raycast-style command palette triggered by ⌘K.
/// Shows all available actions for the focused PR, filterable by typing.
struct CommandPaletteView: View {
    let pr: PRSnapshot
    let writeActionsEnabled: Bool
    let onAction: (TriageAction) -> Void
    @Binding var isPresented: Bool
    var manager: PRManager? = nil

    @State private var filterText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var textFieldFocused: Bool

    private var filteredActions: [TriageAction] {
        let all = TriageAction.allCases
        if filterText.isEmpty { return all }
        let lower = filterText.lowercased()
        return all.filter { $0.label.lowercased().contains(lower) }
    }

    private var filteredScopes: [PRScope] {
        guard let mgr = manager else { return [] }
        if filterText.isEmpty { return mgr.scopeStore.availableScopes }
        let lower = filterText.lowercased()
        return mgr.scopeStore.availableScopes.filter {
            $0.displayName.lowercased().contains(lower)
        }
    }

    private var showAllScopeEntry: Bool {
        filterText.isEmpty || "all".contains(filterText.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter actions…", text: $filterText)
                    .textFieldStyle(.plain)
                    .focused($textFieldFocused)
                    .onSubmit {
                        commitSelection()
                    }
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Action list
            if filteredActions.isEmpty && filteredScopes.isEmpty && !showAllScopeEntry {
                Text("No matching actions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                            actionRow(action: action, index: index)
                        }

                        if let mgr = manager, (!filteredScopes.isEmpty || showAllScopeEntry) {
                            Divider().padding(.vertical, 4)
                            HStack {
                                Text("Switch Scope")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                Spacer()
                            }
                            if showAllScopeEntry {
                                scopeRow(label: "All scopes", scope: nil, mgr: mgr)
                            }
                            ForEach(filteredScopes, id: \.rawValue) { scope in
                                let count = mgr.scopeStore.scopeCounts[scope] ?? 0
                                scopeRow(label: "\(scope.displayName) (\(count))", scope: scope, mgr: mgr)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            Divider()

            // Footer
            HStack {
                Text("↑↓ navigate · ↵ confirm · ⎋ dismiss")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(width: 320)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 16)
        .onAppear {
            textFieldFocused = true
            selectedIndex = 0
        }
        .onChange(of: filterText) { _ in
            selectedIndex = 0
        }
        // Navigation is handled via the TextField's onSubmit + keyboard monitor installed
        // in TriageDeckView. Arrow key / escape handling in TextField is provided by
        // a background NSEvent monitor here for macOS 13 compatibility.
        .background(
            CommandPaletteKeyHandler(
                onUp: { selectedIndex = max(0, selectedIndex - 1) },
                onDown: { selectedIndex = min(filteredActions.count - 1, selectedIndex + 1) },
                onEscape: { isPresented = false },
                onReturn: { commitSelection() }
            )
        )
    }

    private func actionRow(action: TriageAction, index: Int) -> some View {
        let isDisabled = action.requiresWriteActions && !writeActionsEnabled
        return Button {
            if !isDisabled {
                onAction(action)
                isPresented = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbolName)
                    .frame(width: 16)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                Text(action.label)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                Spacer()
                if isDisabled {
                    Text("Write disabled")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commitSelection() {
        guard selectedIndex < filteredActions.count else { return }
        let action = filteredActions[selectedIndex]
        let isDisabled = action.requiresWriteActions && !writeActionsEnabled
        if !isDisabled {
            onAction(action)
            isPresented = false
        }
    }

    private func scopeRow(label: String, scope: PRScope?, mgr: PRManager) -> some View {
        Button {
            mgr.scopeStore.selectedScope = scope
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "building.2")
                    .frame(width: 16)
                    .foregroundStyle(.primary)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CommandPaletteKeyHandler

/// NSRepresentable key handler for the command palette.
/// Handles Up/Down arrow, Escape, and Return via NSEvent monitoring.
/// Required for macOS 13 compatibility (`.onKeyPress` requires macOS 14+).
private struct CommandPaletteKeyHandler: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onEscape: () -> Void
    let onReturn: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyHandlerView()
        view.onUp = onUp
        view.onDown = onDown
        view.onEscape = onEscape
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? KeyHandlerView {
            view.onUp = onUp
            view.onDown = onDown
            view.onEscape = onEscape
            view.onReturn = onReturn
        }
    }

    class KeyHandlerView: NSView {
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onEscape: (() -> Void)?
        var onReturn: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    return self?.handleEvent(event) ?? event
                }
            } else {
                if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            }
        }

        private func handleEvent(_ event: NSEvent) -> NSEvent? {
            switch event.keyCode {
            case 125: onDown?(); return nil   // ↓
            case 126: onUp?(); return nil     // ↑
            case 53:  onEscape?(); return nil // Esc
            case 36:  onReturn?(); return nil // Return
            default:  return event
            }
        }
    }
}
