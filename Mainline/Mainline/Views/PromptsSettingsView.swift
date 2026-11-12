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
            Label("Right-click a PR → Run Prompt, or \(runPromptKeyHint), to start an agent session from a template. In the picker, type to filter, ↑/↓ to choose, ↵ to run — or just write a prompt and pick a harness to ask it directly.",
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
            let ordered = store.config.orderedHarnesses
            ForEach(Array(ordered.enumerated()), id: \.element.key) { index, entry in
                harnessRow(key: entry.key, harness: entry.value, index: index, count: ordered.count)
            }
            Label("The first enabled harness is the default — a free-typed prompt that matches no template asks it first. Disabled harnesses are hidden from the picker and won't run.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// "press “A” in the deck" — or, when an upgrade left the key unbound because its
    /// default was already taken, a pointer to where to assign one.
    private var runPromptKeyHint: String {
        let key = settings.shortcutBindings.runPrompt.key
        return key.isEmpty
            ? "assign a key under Settings → Keyboard (“Run Prompt Template” is unbound)"
            : "press “\(key.uppercased())” in the deck"
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
                     ?? (template.harnessKeys.map { store.config.harnesses[$0]?.label ?? $0 }.joined(separator: " · ")
                         + (template.when.isEmpty ? "" : " · suggested when \(template.when)")))
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Button("Edit") { startEditing(template, isNew: false) }
        }
    }

    private func harnessRow(key: String, harness: HarnessConfig, index: Int, count: Int) -> some View {
        let isDefault = store.config.enabledHarnesses.first?.key == key
        // A disabled harness is not a problem — only a broken enabled one is.
        let problem: PromptError? = harness.isEnabled
            ? PromptEngine.validate(harnessKey: key, config: store.config).first : nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { harness.isEnabled },
                set: { store.setHarnessEnabled(key, $0) }
            ))
            .labelsHidden()
            .help(harness.isEnabled ? "Enabled — click to disable" : "Disabled — click to enable")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("\(harness.label)  ·  \(key)")
                    if problem != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if isDefault { Text("default").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(harness.target).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                if let problem {
                    Text(problem.localizedDescription).font(.caption).foregroundStyle(.orange)
                }
            }
            .opacity(harness.isEnabled ? 1 : 0.5)
            Spacer(minLength: 0)
            Button { store.moveHarness(key, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).help("Higher priority")
            Button { store.moveHarness(key, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1).help("Lower priority")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Editor

    private func editorSection(_ current: PromptTemplate) -> some View {
        let binding = Binding<PromptTemplate>(get: { draft ?? current }, set: { draft = $0 })
        let problems = PromptEngine.validate(binding.wrappedValue, config: store.config)
        return Section(isNew ? "New template" : "Edit “\(current.name)”") {
            TextField("Name", text: binding.name)
            Picker("Harness", selection: Binding(
                get: { binding.wrappedValue.harness },
                set: { new in
                    var t = binding.wrappedValue
                    t.harness = new
                    // The new default can't also be an extra; drop its per-harness body too.
                    t.extraHarnesses.removeAll { $0 == new }
                    t.harnessBodies[new] = nil
                    binding.wrappedValue = t
                }
            )) {
                ForEach(store.config.enabledHarnesses, id: \.key) { Text($0.value.label).tag($0.key) }
                // The template's current harness may be disabled or gone; keep it selectable
                // (flagged) so the picker doesn't silently show a different one.
                if !store.config.enabledHarnesses.contains(where: { $0.key == binding.wrappedValue.harness }) {
                    let current = binding.wrappedValue.harness
                    Text("\(store.config.harnesses[current]?.label ?? current) (\(store.config.harnesses[current] == nil ? "not configured" : "disabled"))")
                        .tag(current)
                }
            }
            let others = store.config.enabledHarnesses.filter { $0.key != binding.wrappedValue.harness }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Also offer on").font(.caption).foregroundStyle(.secondary)
                    ForEach(others, id: \.key) { entry in
                        Toggle(entry.value.label, isOn: Binding(
                            get: { binding.wrappedValue.extraHarnesses.contains(entry.key) },
                            set: { on in
                                var t = binding.wrappedValue
                                t.extraHarnesses.removeAll { $0 == entry.key }
                                if on { t.extraHarnesses.append(entry.key) }
                                binding.wrappedValue = t
                            }
                        ))
                    }
                    Text("In the picker, ← / → switch between them. The first (above) is the default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Check out the PR branch first", isOn: binding.checkout)
            TextField("Suggest when", text: binding.when, prompt: Text("e.g. authored+conflict, authored+ci-failing"))
            Stepper("Priority: \(binding.wrappedValue.priority)", value: binding.priority, in: -100...100)
            Text("Suggested templates float to the top of the picker and menu, higher priority first. `,` = or, `+` = and, `!` = not. States: "
                 + PromptState.tokens.map { "\($0.name) (\($0.meaning))" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: binding.body)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                Text("Placeholders: " + PromptContext.placeholderNames.map { "{{\($0)}}" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(binding.wrappedValue.extraHarnesses, id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt for \(store.config.harnesses[key]?.label ?? key) (empty = same as above)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { binding.wrappedValue.harnessBodies[key] ?? "" },
                        set: { binding.wrappedValue.harnessBodies[key] = $0 }
                    ))
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
                }
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
                    toSave.harnessBodies = toSave.harnessBodies.filter { toSave.harnessKeys.contains($0.key) }
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
