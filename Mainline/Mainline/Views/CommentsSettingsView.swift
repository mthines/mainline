import SwiftUI
import AppKit

/// Settings → Comments. The files in `~/.config/mainline/comments` are the source of truth;
/// this pane is a convenient editor over them (and the buttons to open them).
struct CommentsSettingsView: View {
    @ObservedObject var settings: MainlineSettings
    @ObservedObject var store: CommentTemplateStore

    @State private var draft: CommentTemplate?
    @State private var isNew = false

    var body: some View {
        Section("How it works") {
            Label("Right-click a PR → Comment, or \(commentKeyHint), to post a canned comment on it. In the picker, type to filter, ↑/↓ to choose, ↵ to post — or write a comment and post it as typed. Use this to start a comment-triggered automation such as an agent run.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !settings.writeActionsEnabled {
                Label("Posting comments needs “Enable write actions” (Settings → GitHub).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }

        Section("Comments") {
            if store.templates.isEmpty {
                Text("No comments yet.").foregroundStyle(.secondary)
            }
            ForEach(store.templates) { template in
                templateRow(template)
            }
            HStack {
                Button { startEditing(store.newTemplate(), isNew: true) } label: {
                    Label("New Comment", systemImage: "plus")
                }
                Spacer()
                Button("Open Folder") { store.revealCommentsFolder() }
                Button("Reload") { store.reload() }
            }
            Text(store.commentsDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }

        if let draft {
            editorSection(draft)
        }
    }

    /// "press “W” in the deck" — or a pointer to Keyboard settings when an upgrade left it unbound.
    private var commentKeyHint: String {
        let key = settings.shortcutBindings.addComment.key
        return key.isEmpty
            ? "assign a key under Settings → Keyboard (“Post Comment Template” is unbound)"
            : "press “\(key.uppercased())” in the deck"
    }

    private func templateRow(_ template: CommentTemplate) -> some View {
        let problem = CommentEngine.validate(template).first
        return HStack {
            Image(systemName: problem == nil ? "text.quote" : "exclamationmark.triangle")
                .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(template.name)
                Text(problem?.localizedDescription
                     ?? ((template.scope.isEmpty ? "all repos" : template.scopeText)
                         + (template.when.isEmpty ? "" : " · suggested when \(template.when)")))
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Button("Edit") { startEditing(template, isNew: false) }
        }
    }

    // MARK: Editor

    private func editorSection(_ current: CommentTemplate) -> some View {
        let binding = Binding<CommentTemplate>(get: { draft ?? current }, set: { draft = $0 })
        let problems = CommentEngine.validate(binding.wrappedValue)
        return Section(isNew ? "New comment" : "Edit “\(current.name)”") {
            TextField("Name", text: binding.name)
            TextField("Scope", text: Binding(
                get: { binding.wrappedValue.scopeText },
                set: { binding.wrappedValue.scope = CommentEngine.parseScope($0) }
            ), prompt: Text("e.g. acme/*, me/side-project — empty = all repos"))
            Text("Where this comment is offered: owner/repo, owner/* or *, comma-separated.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Suggest when", text: binding.when, prompt: Text("e.g. authored+ci-failing"))
            Stepper("Priority: \(binding.wrappedValue.priority)", value: binding.priority, in: -100...100)
            Text("Suggested comments float to the top of the picker and menu, higher priority first. `,` = or, `+` = and, `!` = not. States: "
                 + PromptState.tokens.map { "\($0.name) (\($0.meaning))" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Comment").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: binding.body)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                Text("Placeholders: " + CommentEngine.placeholderNames.map { "{{\($0)}}" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(problems.map(\.localizedDescription), id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        store.delete(current)
                        stopEditing()
                    }
                }
                Spacer()
                Button("Cancel") { stopEditing() }
                Button("Save") {
                    var toSave = binding.wrappedValue
                    toSave.name = toSave.name.trimmingCharacters(in: .whitespaces)
                    if toSave.name.isEmpty { toSave.name = "Untitled" }
                    store.save(toSave)
                    stopEditing()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(binding.wrappedValue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func startEditing(_ template: CommentTemplate, isNew: Bool) {
        self.isNew = isNew
        draft = template
    }

    private func stopEditing() {
        draft = nil
        isNew = false
    }
}
