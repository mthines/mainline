import SwiftUI
import AppKit

/// Type-to-filter picker for prompt templates, shown over the deck for one PR.
///
/// ↑/↓ move, ←/→ pick the harness of a template that offers several (only while the query
/// is empty or the caret is at the matching edge, so the arrows still move the cursor in typed text), ↵ runs, Esc closes. Once
/// something is typed, one "Ask" row (with a chip per configured harness) sends the typed
/// text itself as the prompt (about this PR) — so an arbitrary one-off session needs no template.
struct PromptPickerView: View {
    /// What the picker opened for. When it is a stacked PR, Tab switches between the whole
    /// stack and just that PR (`scopeOverride`).
    let initialTarget: PromptTarget
    @ObservedObject var store: PromptTemplateStore
    /// Drives which templates are suggested first (`PromptTarget.state`).
    let myLogin: String
    /// The item to run, and the target as scoped when ↵ was pressed.
    let onRun: (Item, PromptTarget) -> Void
    let onClose: () -> Void

    enum Item: Identifiable {
        /// `reason` is why it is suggested for this PR (nil = not suggested).
        case template(PromptTemplate, reason: String?)
        case custom(harnessKey: String, label: String, text: String)

        var id: String {
            switch self {
            case .template(let t, _): return "t:\(t.fileName)"
            case .custom: return "c:ask"   // one row; ←/→ pick which harness it asks
            }
        }
    }

    @State private var query = ""
    @State private var scopeOverride: Bool?
    @State private var selected = 0
    /// The harness picked with ←/→, per template file; absent = the template's first runnable one.
    @State private var harnessChoice: [String: String] = [:]
    @State private var keyMonitor: Any?
    @FocusState private var fieldFocused: Bool

    private var target: PromptTarget {
        var t = initialTarget
        if let scopeOverride { t.wholeStack = scopeOverride }
        return t
    }

    private var items: [Item] {
        // Filter by the query, then keep suggested-first order (so ↵ on an empty query
        // runs the best fit for this PR's state).
        let matching = Set(PromptEngine.filter(store.templates, query: query, config: store.config).map(\.fileName))
        let config = store.config
        let templates = PromptState.ordered(store.templates, active: target.state(myLogin: myLogin),
                                            canRun: { PromptEngine.blockingErrors($0, config: config).isEmpty })
            .filter { matching.contains($0.template.fileName) }
            .map { Item.template($0.template, reason: $0.reason) }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return templates }
        guard let harness = store.config.enabledHarnesses.first(where: { $0.key == chosenAskHarness }) else { return templates }
        return templates + [.custom(harnessKey: harness.key, label: harness.value.label, text: typed)]
    }

    /// Harnesses the free-typed "Ask" row can use, in priority order.
    private var askChoices: [String] { store.config.enabledHarnesses.map(\.key) }

    /// The one ←/→ picked for the "Ask" row; the default (first enabled) until then.
    private var chosenAskHarness: String? {
        if let key = harnessChoice[Self.askChoiceKey], askChoices.contains(key) { return key }
        return askChoices.first
    }

    private static let askChoiceKey = "\u{0}ask"

    /// Harnesses ←/→ can pick for a template row (never empty: a broken template shows its one).
    private func choices(_ t: PromptTemplate) -> [String] {
        let runnable = PromptEngine.runnableHarnesses(t, config: store.config)
        return runnable.isEmpty ? [t.harness] : runnable
    }

    private func chosenHarness(_ t: PromptTemplate) -> String {
        let all = choices(t)
        if let key = harnessChoice[t.fileName], all.contains(key) { return key }
        return all[0]
    }

    /// The item as it will run: a template pinned to the harness chosen for it.
    private func resolve(_ item: Item) -> Item {
        guard case .template(let t, let reason) = item else { return item }
        return .template(t.resolved(for: chosenHarness(t)), reason: reason)
    }

    var body: some View {
        let rows = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                TextField("Run a prompt on \(target.title) — type to filter, or write your own",
                          text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { run(rows) }
                    .onExitCommand(perform: onClose)
                if initialTarget.isStacked {
                    Button(action: toggleScope) {
                        Text(target.isStack ? "Stack ×\(target.prs.count)  ⇥" : "This PR  ⇥")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Tab: run on the whole stack or just this PR")
                }
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close (Esc)")
            }
            .padding(10)
            Divider()

            if rows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == selected)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onRun(resolve(item), target) }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selected) { index in
                        guard rows.indices.contains(index) else { return }
                        proxy.scrollTo(rows[index].id)
                    }
                }
            }

            Divider()
            keyHints(rows)

            if let error = store.configError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .shadow(radius: 12)
        .onAppear {
            store.reload()
            installKeyMonitor()
            // The field is created in this same pass; focus it on the next tick.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: query) { _ in selected = 0 }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            switch item {
            case .template(let t, let reason):
                let problem = PromptEngine.validate(t, config: store.config).first
                Image(systemName: problem != nil ? "exclamationmark.triangle" : (reason != nil ? "star.fill" : "text.quote"))
                    .foregroundStyle(problem != nil ? Color.orange : (reason != nil ? Color.accentColor : Color.secondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    // Name on the left, harness chips pinned right: chips never shrink,
                    // the name gives way first, so a narrow panel can't squash the chips.
                    HStack(spacing: 8) {
                        Text(t.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if problem == nil { harnessChips(t).fixedSize() }
                    }
                    Text(problem?.localizedDescription ?? subtitle(t, reason: reason))
                        .font(.caption)
                        .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                        .lineLimit(1).truncationMode(.tail)
                }
            case .custom(let key, _, let text):
                Image(systemName: "pencil.line").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Ask").lineLimit(1)
                        Spacer(minLength: 4)
                        chips(askChoices, chosen: key).fixedSize()
                    }
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// "Suggested: authored + ready · checks out the PR branch" — what is left once the chips
    /// have their own place on the title line.
    private func subtitle(_ t: PromptTemplate, reason: String?) -> String {
        var parts: [String] = []
        if let reason { parts.append("Suggested: \(reason)") }
        if t.checkout { parts.append("checks out the PR branch") }
        return parts.isEmpty ? "Runs on \(harnessLabel(chosenHarness(t)))" : parts.joined(separator: " · ")
    }

    /// One chip per harness the template can run on; the chosen one is highlighted, so a
    /// single-harness template reads as its plain label.
    @ViewBuilder
    private func harnessChips(_ t: PromptTemplate) -> some View {
        chips(choices(t), chosen: chosenHarness(t))
    }

    @ViewBuilder
    private func chips(_ all: [String], chosen: String) -> some View {
        if all.count == 1 {
            Text(harnessLabel(chosen)).font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(all, id: \.self) { key in
                Text(harnessLabel(key))
                    .font(.caption)
                    .foregroundStyle(key == chosen ? Color.primary : Color.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(key == chosen ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), in: Capsule())
            }
        }
    }

    /// Footer: the keys that work right now. ←/→ only appear while the highlighted row
    /// is a template that offers more than one harness.
    private func keyHints(_ rows: [Item]) -> some View {
        var hints = ["↑↓ move"]
        if rows.indices.contains(selected), cycleOptions(rows[selected]) != nil {
            hints.append("←→ harness")
        }
        hints += ["↵ run"]
        if initialTarget.isStacked { hints.append("⇥ stack / PR") }
        hints.append("esc close")
        return Text(hints.joined(separator: "  ·  "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No templates yet").font(.callout)
            Text("Add Markdown files to ~/.config/mainline/prompts, or create one in Settings → Prompts.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private func harnessLabel(_ key: String) -> String {
        store.config.harnesses[key]?.label ?? "\(key) (not configured)"
    }

    // MARK: Actions + keys

    private func run(_ rows: [Item]) {
        guard rows.indices.contains(selected) else { return }
        onRun(resolve(rows[selected]), target)
    }

    /// What ←/→ cycle for `item`: its harness choices, the chosen one, and where the choice is
    /// stored. nil when there is only one harness (the key then passes through to the field).
    private func cycleOptions(_ item: Item) -> (keys: [String], chosen: String, slot: String)? {
        switch item {
        case .template(let t, _):
            let all = choices(t)
            return all.count > 1 ? (all, chosenHarness(t), t.fileName) : nil
        case .custom:
            guard askChoices.count > 1, let chosen = chosenAskHarness else { return nil }
            return (askChoices, chosen, Self.askChoiceKey)
        }
    }

    /// ←/→ on a row that offers several harnesses: cycle which one ↵ runs.
    private func cycleHarness(_ delta: Int) -> Bool {
        let rows = items
        guard rows.indices.contains(selected), let o = cycleOptions(rows[selected]),
              let index = o.keys.firstIndex(of: o.chosen) else { return false }
        harnessChoice[o.slot] = o.keys[(index + delta + o.keys.count) % o.keys.count]
        return true
    }

    private func toggleScope() {
        guard initialTarget.isStacked else { return }
        scopeOverride = !target.wholeStack
        selected = 0
    }

    /// ↑/↓ must be intercepted: in a single-line `NSTextField` they move the cursor to
    /// the line's ends instead of reaching SwiftUI. Same technique as the search bar's
    /// Down handoff; installed only while the picker is on screen.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: move(1);  return nil   // Down
            case 126: move(-1); return nil   // Up
            // Plain ←/→ cycle the harness only when the caret has nowhere to go (see
            // plainArrowCyclesHarness); otherwise they fall through to the field.
            case 123 where plainArrowCyclesHarness(event) && cycleHarness(-1): return nil   // Left
            case 124 where plainArrowCyclesHarness(event) && cycleHarness(1):  return nil   // Right
            case 48 where initialTarget.isStacked:   // Tab: whole stack ↔ this PR
                toggleScope(); return nil
            default:  return event
            }
        }
    }

    /// Plain ←/→ cycle the harness when the field has nothing to move: an empty query, or a
    /// caret already at the edge the arrow points to (→ at the end, ← at the start) with no
    /// selection. Anywhere else the arrow stays a cursor move.
    private func plainArrowCyclesHarness(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        if query.isEmpty { return true }
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        let range = editor.selectedRange()
        guard range.length == 0 else { return false }
        return event.keyCode == 124 ? range.location >= (editor.string as NSString).length : range.location == 0
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selected = min(max(selected + delta, 0), count - 1)
    }
}
