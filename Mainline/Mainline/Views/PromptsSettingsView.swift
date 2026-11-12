import SwiftUI
import AppKit

/// Settings → Prompts. The files in `~/.config/mainline` are the source of truth;
/// this pane is a convenient editor over them (and the buttons to open them).
struct PromptsSettingsView: View {
    @ObservedObject var settings: MainlineSettings
    @ObservedObject var store: PromptTemplateStore

    /// File name of the template being edited, plus its working copy.
    @State private var editingFile: String?
    @State private var draft: PromptTemplate?
    @State private var isNew = false

    var body: some View {
        Section("How it works") {
            Label("Right-click a PR → Run Prompt, or press \(runPromptKeyLabel) in the deck, to start an agent session from a template. In the picker, type to filter, ↑/↓ to choose, ↵ to run — or just write a prompt and pick a harness to ask it directly.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Terminal") {
            Picker("Open CLI harnesses in", selection: $settings.promptTerminal) {
                ForEach(PromptTerminal.allCases) { terminal in
                    Text(terminal.displayName + (terminal.isInstalled ? "" : " — not installed"))
                        .tag(terminal)
                }
            }
            Label("Web harnesses always open in your browser.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Templates") {
            if store.templates.isEmpty {
                Text("No templates yet.").foregroundStyle(.secondary)
            }
            ForEach(store.templates) { template in
                templateRow(template)
            }
            HStack {
                Button { startEditing(store.newTemplate(), isNew: true) } label: {
                    Label("New Template", systemImage: "plus")
                }
                Spacer()
                Button("Open Folder") { store.revealPromptsFolder() }
                Button("Reload") { store.reload() }
            }
            Text(store.promptsDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }

        if let draft {
            editorSection(draft)
        }

        Section("Harnesses & repositories") {
            ForEach(store.config.orderedHarnesses, id: \.key) { entry in
                harnessRow(key: entry.key, harness: entry.value)
            }
            if let error = store.configError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("\(store.config.repos.count) repo path\(store.config.repos.count == 1 ? "" : "s") mapped")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open config.json") { store.openConfig() }
            }
            Label("config.json holds harness commands/URLs (each must contain {{prompt}}), the owner/repo → local path map CLI harnesses start in, and the checkout step. See README.txt in the prompts folder.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.reload() }
    }

    private var runPromptKeyLabel: String {
        "“\(settings.shortcutBindings.runPrompt.key.uppercased())”"
    }

    // MARK: Rows

    private func templateRow(_ template: PromptTemplate) -> some View {
        let problem = PromptEngine.validate(template, config: store.config).first
        return HStack {
            Image(systemName: problem == nil ? "text.quote" : "exclamationmark.triangle")
                .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(template.name)
                Text(problem?.localizedDescription
                     ?? (store.config.harnesses[template.harness]?.label ?? template.harness))
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Button("Edit") { startEditing(template, isNew: false) }
        }
    }

    private func harnessRow(key: String, harness: HarnessConfig) -> some View {
        let problem = PromptEngine.validate(harnessKey: key, config: store.config).first
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: problem == nil ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(problem == nil ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(harness.label)  ·  \(key)")
                Text(harness.target).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                if let problem {
                    Text(problem.localizedDescription).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Editor

    private func editorSection(_ current: PromptTemplate) -> some View {
        let binding = Binding<PromptTemplate>(get: { draft ?? current }, set: { draft = $0 })
        let problems = PromptEngine.validate(binding.wrappedValue, config: store.config)
        return Section(isNew ? "New template" : "Edit “\(current.name)”") {
            TextField("Name", text: binding.name)
            Picker("Harness", selection: binding.harness) {
                ForEach(store.config.orderedHarnesses, id: \.key) { Text($0.value.label).tag($0.key) }
                if store.config.harnesses[binding.wrappedValue.harness] == nil {
                    Text("\(binding.wrappedValue.harness) (not configured)").tag(binding.wrappedValue.harness)
                }
            }
            Toggle("Check out the PR branch first", isOn: binding.checkout)
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: binding.body)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                Text("Placeholders: " + PromptContext.placeholderNames.map { "{{\($0)}}" }.joined(separator: " "))
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
            }
        }
    }

    private func startEditing(_ template: PromptTemplate, isNew: Bool) {
        self.isNew = isNew
        editingFile = template.fileName
        draft = template
    }

    private func stopEditing() {
        editingFile = nil
        draft = nil
        isNew = false
    }
}
