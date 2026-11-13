import SwiftUI
import AppKit

/// Type-to-filter picker for canned PR comments, shown over the deck for one PR.
///
/// ↑/↓ move, ↵ posts, Esc closes. Only comments scoped to the PR's repo are listed. Once
/// something is typed, one "Post as typed" row posts that text itself, so a one-off
/// comment needs no template. Posting a comment can start a comment-triggered agent run,
/// so the highlighted row's full text is previewed before ↵.
struct CommentPickerView: View {
    let pr: PRSnapshot
    @ObservedObject var store: CommentTemplateStore
    /// Drives which comments are suggested first.
    let myLogin: String
    /// Called with the final text and the template name (nil for typed text).
    let onPost: (String, String?) -> Void
    let onClose: () -> Void

    enum Item: Identifiable {
        case template(CommentTemplate, reason: String?)
        case typed(String)

        var id: String {
            switch self {
            case .template(let t, _): return "t:\(t.fileName)"
            case .typed: return "c:typed"
            }
        }
    }

    @State private var query = ""
    @State private var selected = 0
    @State private var keyMonitor: Any?
    @FocusState private var fieldFocused: Bool

    private var items: [Item] {
        let ranked = CommentEngine.ordered(store.templates, repo: pr.repoFullName,
                                           active: PromptState.active(pr: pr, myLogin: myLogin))
        var rows = CommentEngine.filter(ranked, query: query).map { Item.template($0.template, reason: $0.reason) }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { rows.append(.typed(typed)) }
        return rows
    }

    /// The text ↵ would post for `item`, or why it can't be posted.
    private func resolve(_ item: Item) -> Result<(text: String, label: String?), Error> {
        switch item {
        case .template(let t, _):
            if let problem = CommentEngine.validate(t).first { return .failure(problem) }
            do { return .success((try CommentEngine.render(t, for: pr), t.name)) } catch { return .failure(error) }
        case .typed(let text):
            return .success((text, nil))   // literal: never run through the placeholder engine
        }
    }

    var body: some View {
        let rows = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                TextField("Comment on #\(pr.number) (\(pr.repoFullName)) — type to filter, or write your own",
                          text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { post(rows) }
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
                                    // Double-click posts; a single click only highlights, so
                                    // clicking a row to read its preview never publishes it.
                                    .onTapGesture(count: 2) { selected = index; post(rows) }
                                    .onTapGesture { selected = index }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .onChange(of: selected) { index in
                        guard rows.indices.contains(index) else { return }
                        proxy.scrollTo(rows[index].id)
                    }
                }
                preview(rows)
            }

            Divider()
            Text("↑↓ move  ·  ↵ post comment  ·  esc close")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .shadow(radius: 12)
        .onAppear {
            store.reload()
            installKeyMonitor()
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
                let problem = CommentEngine.validate(t).first
                Image(systemName: problem != nil ? "exclamationmark.triangle" : (reason != nil ? "star.fill" : "text.quote"))
                    .foregroundStyle(problem != nil ? Color.orange : (reason != nil ? Color.accentColor : Color.secondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).lineLimit(1).truncationMode(.tail)
                    Text(problem?.localizedDescription ?? subtitle(t, reason: reason))
                        .font(.caption)
                        .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                        .lineLimit(1).truncationMode(.tail)
                }
            case .typed(let text):
                Image(systemName: "pencil.line").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Post as typed").lineLimit(1)
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// "Suggested: authored + ci-failing" or the first line of the text.
    private func subtitle(_ t: CommentTemplate, reason: String?) -> String {
        if let reason { return "Suggested: \(reason)" }
        return t.body.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// The exact text that ↵ will post, for the highlighted row.
    @ViewBuilder
    private func preview(_ rows: [Item]) -> some View {
        if rows.indices.contains(selected) {
            Divider()
            switch resolve(rows[selected]) {
            case .success(let result):
                Text(result.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No comments for \(pr.repoFullName)").font(.callout)
            Text("Add Markdown files to ~/.config/mainline/comments (set `scope:` to limit them to an org or repo), or create one in Settings → Comments. Typing a comment here posts it as written.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions + keys

    private func post(_ rows: [Item]) {
        guard rows.indices.contains(selected) else { return }
        if case .success(let result) = resolve(rows[selected]) { onPost(result.text, result.label) }
    }

    /// ↑/↓ must be intercepted: in a single-line `NSTextField` they move the cursor to the
    /// line's ends instead of reaching SwiftUI. Installed only while the picker is on screen.
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
