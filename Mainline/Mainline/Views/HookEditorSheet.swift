import SwiftUI
import AppKit

/// The Settings sheet that edits one prompt template or hook (flag `hook-editor`).
///
/// It opens small: a name, WHEN it runs, WHICH PRs, and the prompt. Repos, guard, harness and
/// priority fold into "Advanced", each closed group showing a one-line summary. All logic that is not
/// layout lives in the pure `PRHookEngine` / `PromptEngine` helpers (and their self-checks).
struct HookEditorSheet: View {
    @ObservedObject var settings: MainlineSettings
    @ObservedObject var store: PromptTemplateStore
    @State var draft: PromptTemplate
    let isNew: Bool
    /// Opened from the Hooks list (hook groups shown flat) or the Templates list (they fold away).
    let isHookMode: Bool
    let onClose: () -> Void

    @State private var advancedOpen = false
    @State private var statesOpen = false
    @State private var roleBeforeAny = "authored"
    @State private var automaticOpen = false
    @State private var confirmDelete = false

    init(settings: MainlineSettings, store: PromptTemplateStore, draft: PromptTemplate, isNew: Bool, isHookMode: Bool,
         onClose: @escaping () -> Void) {
        self.settings = settings
        self.store = store
        self._draft = State(initialValue: draft)
        self.isNew = isNew
        self.isHookMode = isHookMode
        self.onClose = onClose
    }

    private var issueHooks: Bool { FeatureFlagRegistry.issueHooksEnabled }
    private var checkHooks: Bool { FeatureFlagRegistry.checkHooksEnabled }
    private var hasHookConfig: Bool { !draft.on.trimmingCharacters(in: .whitespaces).isEmpty || !draft.hookEnabled }
    private var isHook: Bool { isHookMode || hasHookConfig }
    private var harnessLabel: String { store.config.harnesses[draft.harness]?.label ?? draft.harness }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if isHookMode {
                        hookGroups
                    } else {
                        ButtonDisclosure(isExpanded: $automaticOpen) {
                            hookGroups.padding(.top, 8)
                        } label: {
                            summaryLabel("Run automatically", hasHookConfig ? PRHookEngine.describe(draft) : "Off. Starts only when you run it.")
                        }
                    }
                    promptGroup
                    advancedGroup
                    problemList
                }
                .padding(20)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 580, height: 640)
        .onAppear { automaticOpen = hasHookConfig }
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(draft); onClose() }
        } message: { Text("The file is removed from the prompts folder.") }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).font(.headline)
            if isHook {
                Toggle("On", isOn: $draft.hookEnabled).toggleStyle(.switch)
                    .help(draft.hookEnabled ? "Switch off: it keeps its settings but never runs" : "Switch on to let it start by itself")
            }
        }
    }

    // MARK: When and which PRs

    @ViewBuilder private var hookGroups: some View {
        VStack(alignment: .leading, spacing: 16) {
            whenGroup
            whichGroup
            consent
        }
    }

    private var rows: [HookTriggerRow] {
        switch draft.subject {
        case .prs: return PRHookEngine.prTriggerRows(checks: checkHooks)
        case .issues: return PRHookEngine.issueTriggerRows
        case .both: return PRHookEngine.prTriggerRows(checks: checkHooks) + PRHookEngine.issueTriggerRows
        }
    }

    /// Changing the subject drops the known trigger words its rows no longer offer, so none is left ticked
    /// with no row to untick it. Unknown words stay, so the sheet still reports them.
    private var subjectBinding: Binding<PromptSubject> {
        Binding(
            get: { draft.subject },
            set: { new in
                draft.subject = new
                draft.on = PRHookEngine.pruneTriggers(draft.on, offered: Set(rows.flatMap { $0.outcomes.map(\.raw) }))
            })
    }

    private var ticked: Set<String> { PRHookEngine.tickedTriggers(draft.on) }

    private func binding(for raw: String) -> Binding<Bool> {
        Binding(
            get: { ticked.contains(raw) },
            set: { on in
                var set = ticked
                if on { set.insert(raw) } else { set.remove(raw) }
                draft.on = PRHookEngine.composeTriggers(set, keeping: draft.on)
            })
    }

    private var whenGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("When").font(.headline)
                Spacer()
                if issueHooks {
                    Picker("About", selection: subjectBinding) {
                        Text("Pull requests").tag(PromptSubject.prs)
                        Text("Issues").tag(PromptSubject.issues)
                        if draft.subject == .both { Text("Both").tag(PromptSubject.both) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }
            ForEach(rows, id: \.title) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.title)
                        if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(width: 150, alignment: .leading)
                    HStack(spacing: 6) {
                        ForEach(row.outcomes, id: \.raw) { outcome in
                            Toggle(outcome.label, isOn: binding(for: outcome.raw)).toggleStyle(.button)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if row.needsCheckName, row.outcomes.contains(where: { ticked.contains($0.raw) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Check name", text: $draft.hookCheck)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Text("Exact name, any letter case. * matches any run of characters.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 160)
                }
            }
            if ticked.count > 1 {
                Text("This prompt runs for each of these.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var roleOptions: [(label: String, raw: String)] {
        draft.subject == .issues
            ? [("Your issues", "authored"), ("Any issue", "any")]
            : [("Your PRs", "authored"), ("PRs you review", "reviewing"), ("Anyone's", "any")]
    }

    private var roleBinding: Binding<String> {
        Binding(get: { HookRole.parse(draft.hookRole).rawValue }, set: { draft.hookRole = $0 })
    }

    private var whichGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.subject == .issues ? "Which issues" : "Which PRs").font(.headline)
            // Two choices up front; “Anyone's” is the wide one, reachable from Advanced.
            Picker("Which", selection: roleBinding) {
                ForEach(roleOptions.filter { $0.raw != "any" || HookRole.parse(draft.hookRole) == .any }, id: \.raw) {
                    Text($0.label).tag($0.raw)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(HookRole.parse(draft.hookRole) == .authored
                 ? "Your own work is the safe default."
                 : "This starts agents on work that isn't yours.")
                .font(.caption)
                .foregroundStyle(HookRole.parse(draft.hookRole) == .authored ? Color.secondary : Color.orange)
        }
    }

    private var consent: some View {
        let armed = draft.hookEnabled && !ticked.isEmpty
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: armed ? "exclamationmark.triangle.fill" : "info.circle")
                .accessibilityHidden(true)
            Text(PRHookEngine.consentLine(draft, harnessLabel: harnessLabel, countdownSeconds: settings.hookCountdownSeconds))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(armed ? Color.orange : Color.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill((armed ? Color.orange : Color.gray).opacity(0.12)))
    }

    // MARK: Prompt

    private var placeholders: [String] {
        PromptContext.placeholderNames.filter { name in
            switch draft.subject {
            case .prs: return !name.hasPrefix("issue")
            case .issues: return !name.hasPrefix("pr.") && !name.hasPrefix("stack.")
            case .both: return true
            }
        }
    }

    private var promptGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt").font(.headline)
            TextEditor(text: $draft.body).font(.body.monospaced()).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            Menu("Insert placeholder") {
                ForEach(placeholders, id: \.self) { name in
                    Button("{{\(name)}}") { draft.body += (draft.body.isEmpty || draft.body.hasSuffix(" ") ? "" : " ") + "{{\(name)}}" }
                }
            }
            .fixedSize()
            ForEach(draft.extraHarnesses, id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt for \(store.config.harnesses[key]?.label ?? key) (empty = same as above)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { draft.harnessBodies[key] ?? "" },
                        set: { draft.harnessBodies[key] = $0 }))
                        .font(.body.monospaced()).frame(minHeight: 70)
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedSummary: String {
        var parts = [draft.hookScope.trimmingCharacters(in: .whitespaces).isEmpty ? "All repos" : draft.hookScope, harnessLabel]
        if !isHook { parts.append(draft.checkout ? "checks out the branch" : "no checkout") }
        return parts.joined(separator: " · ")
    }

    private func summaryLabel(_ title: String, _ summary: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var advancedGroup: some View {
        ButtonDisclosure(isExpanded: $advancedOpen) {
            VStack(alignment: .leading, spacing: 10) {
                if isHook {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Repos", text: $draft.hookScope, prompt: Text("All repos. e.g. dash0hq/*, owner/repo"))
                            .textFieldStyle(.roundedBorder)
                        if let message = PRHookEngine.scopeProblem(draft.hookScope) {
                            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        } else if draft.hookScope.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Empty means every repo you can see.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Toggle("Also start on anyone's work", isOn: Binding(
                        get: { HookRole.parse(draft.hookRole) == .any },
                        set: { on in
                            if on {
                                if HookRole.parse(draft.hookRole) != .any { roleBeforeAny = HookRole.parse(draft.hookRole).rawValue }
                                draft.hookRole = "any"
                            } else {
                                draft.hookRole = roleBeforeAny
                            }
                        }))
                    Text("Widens “\(draft.subject == .issues ? "Which issues" : "Which PRs")” above to every \(draft.subject == .issues ? "issue" : "PR") you can see, yours or not. Off is the safe default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isHook {
                    Toggle("Also start on my own comments and reviews", isOn: $draft.hookSelf)
                    Text("Off by default: an agent that comments back as you would start itself again. Pair it with a run limit.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Stepper(value: Binding(get: { draft.hookMaxRuns }, set: { draft.hookMaxRuns = max(0, $0) }), in: 0...50) {
                        Text(draft.hookMaxRuns == 0
                             ? "Run limit per \(draft.subject == .issues ? "issue" : "PR"): none"
                             : "Run limit per \(draft.subject == .issues ? "issue" : "PR"): \(draft.hookMaxRuns)")
                    }
                    Text("Counted across launches and kept until you raise or remove it. A start you cancel does not count.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                TextField("Only when", text: $draft.when, prompt: Text("e.g. conflict + !draft"))
                    .textFieldStyle(.roundedBorder)
                Text("`,` = or, `+` = and, `!` = not. \(isHook ? "Leave empty to start on every matching event." : "Leave empty and it is never suggested.")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ButtonDisclosure(isExpanded: $statesOpen) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(PromptState.tokens, id: \.name) { token in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(token.name).font(.caption.monospaced()).frame(width: 150, alignment: .leading)
                                Text(token.meaning).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("These read the PR as GitHub reports it: its checks, reviews and mergeability.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                        HStack(spacing: 12) {
                            Link("Status checks", destination: URL(string: "https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/about-status-checks")!)
                            Link("Reviews", destination: URL(string: "https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/about-pull-request-reviews")!)
                            Link("Merge conflicts", destination: URL(string: "https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/addressing-merge-conflicts/about-merge-conflicts")!)
                        }.font(.caption)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Which states can I use?").font(.caption)
                }
                Picker("Harness", selection: Binding(
                    get: { draft.harness },
                    set: { new in
                        draft.harness = new
                        draft.extraHarnesses.removeAll { $0 == new }
                        draft.harnessBodies[new] = nil
                    })) {
                    ForEach(store.config.enabledHarnesses, id: \.key) { Text($0.value.label).tag($0.key) }
                    if !store.config.enabledHarnesses.contains(where: { $0.key == draft.harness }) {
                        Text("\(harnessLabel) (unavailable)").tag(draft.harness)
                    }
                }
                if !isHook {
                    let others = store.config.enabledHarnesses.filter { $0.key != draft.harness }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Also offer on").font(.caption).foregroundStyle(.secondary)
                            ForEach(others, id: \.key) { entry in
                                Toggle(entry.value.label, isOn: Binding(
                                    get: { draft.extraHarnesses.contains(entry.key) },
                                    set: { on in
                                        draft.extraHarnesses.removeAll { $0 == entry.key }
                                        if on { draft.extraHarnesses.append(entry.key) }
                                    }))
                            }
                        }
                    }
                    Toggle("Check out the PR branch first", isOn: $draft.checkout)
                } else {
                    Text("Hooks never check out the branch. Ask the agent to open a worktree in the prompt if it needs the code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Priority: \(draft.priority)", value: $draft.priority, in: -100...100)
            }
            .padding(.top, 8)
        } label: {
            summaryLabel("Advanced", advancedSummary)
        }
    }

    // MARK: Problems and footer

    private var problems: [String] {
        var out = PromptEngine.validate(draft, config: store.config).map(\.localizedDescription)
        if isHook { out += PRHookEngine.problems(draft, issues: issueHooks, checks: checkHooks) }
        return out
    }

    @ViewBuilder private var problemList: some View {
        ForEach(problems, id: \.self) { message in
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    /// Saves and returns the template under the file name it ended up with (it can be renamed).
    @discardableResult
    private func save() -> PromptTemplate {
        var toSave = draft
        toSave.name = toSave.name.trimmingCharacters(in: .whitespaces)
        if toSave.name.isEmpty { toSave.name = "Untitled" }
        toSave.harnessBodies = toSave.harnessBodies.filter { toSave.harnessKeys.contains($0.key) }
        return store.save(toSave)
    }

    private var footer: some View {
        HStack {
            if !isNew { Button("Delete", role: .destructive) { confirmDelete = true } }
            Button("Open in Editor") { store.openInEditor(save()); onClose() }
                .help("Saves, then opens the file in your editor")
            Spacer()
            Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
            Button(isNew && isHookMode ? "Add hook" : "Save") { save(); onClose() }
                .keyboardShortcut(.defaultAction)
        }
    }
}


/// A disclosure whose whole header row is a button. SwiftUI's `DisclosureGroup` only reacts to its chevron
/// on macOS, and inside this sheet's ScrollView it did not open at all.
private struct ButtonDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 12)
                    label()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            if isExpanded { content().padding(.leading, 18) }
        }
    }
}
