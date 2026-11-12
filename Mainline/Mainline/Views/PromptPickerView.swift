import SwiftUI
import AppKit

/// Type-to-filter picker for prompt templates, shown over the deck for one PR.
///
/// ↑/↓ move, ↵ runs, Esc closes. Once something is typed, every configured harness
/// also gets an "Ask …" row that sends the typed text itself as the prompt (about
/// this PR) — so an arbitrary one-off session needs no template.
struct PromptPickerView: View {
    let pr: PRSnapshot
    @ObservedObject var store: PromptTemplateStore
    let onRun: (Item) -> Void
    let onClose: () -> Void

    enum Item: Identifiable {
        case template(PromptTemplate)
        case custom(harnessKey: String, label: String, text: String)

        var id: String {
            switch self {
            case .template(let t): return "t:\(t.fileName)"
            case .custom(let key, _, _): return "c:\(key)"
            }
        }
    }

    @State private var query = ""
    @State private var selected = 0
    @State private var keyMonitor: Any?
    @FocusState private var fieldFocused: Bool

    private var items: [Item] {
        let templates = PromptEngine.filter(store.templates, query: query, config: store.config)
            .map(Item.template)
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return templates }
        let custom = store.config.orderedHarnesses.map {
            Item.custom(harnessKey: $0.key, label: $0.value.label, text: typed)
        }
        return templates + custom
    }

    var body: some View {
        let rows = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                TextField("Run a prompt on #\(String(pr.number)) — type to filter, or write your own",
                          text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { run(rows) }
                    .onExitCommand(perform: onClose)
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
                                    .onTapGesture { onRun(item) }
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
            case .template(let t):
                let problem = PromptEngine.validate(t, config: store.config).first
                Image(systemName: problem == nil ? "text.quote" : "exclamationmark.triangle")
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).lineLimit(1)
                    Text(problem?.localizedDescription ?? harnessLabel(t.harness) + (t.checkout ? " · checks out the PR branch" : ""))
                        .font(.caption)
                        .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
            case .custom(_, let label, let text):
                Image(systemName: "pencil.line").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask \(label)").lineLimit(1)
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isSelected { Text("↵").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
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
        onRun(rows[selected])
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
            default:  return event
            }
        }
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
