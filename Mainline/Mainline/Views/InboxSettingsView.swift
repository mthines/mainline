import SwiftUI

// MARK: - InboxSettingsView

/// Settings detail view for the Inbox noise-filter category.
/// Wired into `SettingsView` as `SettingsCategory.inbox`.
///
/// Contains:
///  - Mute-patterns list editor (glob patterns matched against title + head branch)
///  - "Mute bot-authored PRs" toggle (dependabot, renovate, …)
///  - Review focus authors + teams (comma-separated, empty = show all)
///  - Mute-labels list (comma-separated, org-specific)
struct InboxSettingsView: View {
    @ObservedObject var settings: MainlineSettings

    /// Repo owners seen across the current PRs, so the orgs you review show up as
    /// Focus sections without having to type them. Union'd with configured + added
    /// orgs in `focusOrgs`.
    var knownOrgs: [String] = []

    /// Text for the "add an org" field (orgs you don't currently have PRs from).
    @State private var newOrg = ""
    /// Orgs added this session via the add field but not yet in `knownOrgs` or the
    /// saved config — kept so their (initially empty) section stays rendered.
    @State private var sessionOrgs: [String] = []

    var body: some View {
        Section("Pattern Muting") {
            TextField(
                "Mute patterns",
                text: mutePatternsBinding,
                prompt: Text("chore(deps)*, build(deps)*")
            )
            .textFieldStyle(.roundedBorder)
            Label("Comma-separated glob patterns (case-insensitive, * wildcard) matched against PR title AND head branch. Matching PRs are demoted to the Muted group in the Inbox.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Bot Authors") {
            Toggle(
                "Mute bot-authored PRs (dependabot, renovate, github-actions, …)",
                isOn: Binding(
                    get: { settings.muteBotAuthors },
                    set: { newValue in
                        settings.muteBotAuthors = newValue
                        TelemetryService.shared.recordSettingChanged(name: "muteBotAuthors", enabled: newValue)
                    }
                )
            )
            Label("Demotes PRs whose author login ends with [bot] or matches a known dependency-management bot. Helps silence automated dependency bumps in the Inbox.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.muteBotAuthors {
                TextField(
                    "Bot exceptions",
                    text: botAllowListBinding,
                    prompt: Text("release-bot[bot], my-automation[bot]")
                )
                .textFieldStyle(.roundedBorder)
                Label("Comma-separated bot logins that are exempt from the mute rule above. PRs authored by these bots stay active even when \"Mute bot-authored PRs\" is on. Use the full GitHub login (e.g. \"release-bot[bot]\").",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section("Review Focus") {
            Label("Focus is set per org. For each org below, list the authors and teams whose PRs should stay in \"Needs your review\" — everything else in that org is demoted to Muted. An org with no entries shows all of its PRs, and a rule in one org never affects another.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Add an org (e.g. dash0hq)", text: $newOrg)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addOrg)
                Button("Add", action: addOrg)
                    .disabled(trimmedNewOrg.isEmpty)
            }

            // Per-org sub-blocks live INSIDE this section so they read as children
            // of "Review Focus" rather than as siblings of the other mute cards.
            ForEach(focusOrgs, id: \.self) { org in
                orgFocusBlock(org)
            }
        }

        Section("Label Muting") {
            TextField(
                "Mute labels",
                text: muteLabelsBinding,
                prompt: Text("dependencies, automated")
            )
            .textFieldStyle(.roundedBorder)
            Label("Comma-separated label names (case-insensitive). PRs carrying any of these labels are demoted in the Inbox. Add your org's dependency-management or low-priority labels here (e.g. \"dependencies\", \"chore\", \"automated\").",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Per-org focus block

    /// One org's focus editor: a header row (org name + Remove) and the two
    /// allow-list fields, laid out as a single card row so the whole block reads
    /// as belonging to the enclosing "Review Focus" section.
    @ViewBuilder
    private func orgFocusBlock(_ org: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(org)
                    .font(.headline)
                Spacer()
                if canRemove(org) {
                    Button(role: .destructive) {
                        removeOrg(org)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            LabeledContent("Focus authors") {
                TextField("", text: focusAuthorsBinding(for: org), prompt: Text("alice, bob"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            LabeledContent("Focus teams") {
                TextField("", text: focusTeamsBinding(for: org), prompt: Text("ai, platform"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }

            Text("Comma-separated logins / team slugs. A PR is kept if its author OR a requested team matches. Empty = all \(org) PRs stay active.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Comma-separated bindings

    /// Bridges `mutePatterns: [String]` to a single comma-separated text field.
    private var mutePatternsBinding: Binding<String> {
        Binding(
            get: { settings.mutePatterns.joined(separator: ", ") },
            set: { newValue in
                settings.mutePatterns = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    // MARK: - Per-org review focus

    /// Trimmed contents of the "add an org" field.
    private var trimmedNewOrg: String {
        newOrg.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Orgs to render a Focus section for: those with current PRs, those already
    /// configured, and those added this session. De-duplicated case-insensitively
    /// (GitHub org logins are case-insensitive, and the engine + storage key on the
    /// lowercased form) with `knownOrgs`' canonical casing preferred for display.
    private var focusOrgs: [String] {
        var byLower: [String: String] = [:]
        for org in knownOrgs { byLower[org.lowercased()] = org }
        for org in settings.reviewFocusByOrg.keys where byLower[org.lowercased()] == nil {
            byLower[org.lowercased()] = org
        }
        for org in sessionOrgs where byLower[org.lowercased()] == nil {
            byLower[org.lowercased()] = org
        }
        return byLower.values.sorted()
    }

    /// Canonical storage key for an org's focus config — lowercased so two case
    /// variants can never persist as separate entries and the engine's
    /// case-insensitive lookup stays deterministic.
    private func focusKey(_ org: String) -> String { org.lowercased() }

    /// Whether the org has removable state — a saved config, or a section you added
    /// this session. Orgs shown purely because you have open PRs there (and haven't
    /// configured focus) have nothing to remove, so no button is offered; clearing
    /// their fields is the same as "show all".
    private func canRemove(_ org: String) -> Bool {
        settings.reviewFocusByOrg[focusKey(org)] != nil
            || sessionOrgs.contains { $0.caseInsensitiveCompare(org) == .orderedSame }
    }

    /// Removes an org's focus rule: clears its saved config and drops it from the
    /// session-added list. A configured-only org (no open PRs) disappears; an org
    /// you actively review reverts to its "show all" state and stays listed.
    private func removeOrg(_ org: String) {
        settings.reviewFocusByOrg[focusKey(org)] = nil
        sessionOrgs.removeAll { $0.caseInsensitiveCompare(org) == .orderedSame }
    }

    /// Adds a manually-typed org (one you don't currently have PRs from) so its
    /// Focus section appears. Case-insensitive de-dupe against the existing list.
    private func addOrg() {
        let org = trimmedNewOrg
        guard !org.isEmpty,
              !focusOrgs.contains(where: { $0.caseInsensitiveCompare(org) == .orderedSame })
        else { newOrg = ""; return }
        sessionOrgs.append(org)
        newOrg = ""
    }

    /// Bridges one org's `authors` list to a comma-separated text field.
    private func focusAuthorsBinding(for org: String) -> Binding<String> {
        Binding(
            get: { settings.reviewFocusByOrg[focusKey(org)]?.authors.joined(separator: ", ") ?? "" },
            set: { newValue in updateFocus(org: org) { $0.authors = parseCSV(newValue) } }
        )
    }

    /// Bridges one org's `teams` list to a comma-separated text field.
    private func focusTeamsBinding(for org: String) -> Binding<String> {
        Binding(
            get: { settings.reviewFocusByOrg[focusKey(org)]?.teams.joined(separator: ", ") ?? "" },
            set: { newValue in updateFocus(org: org) { $0.teams = parseCSV(newValue) } }
        )
    }

    /// Mutates one org's focus config (keyed on the canonical lowercased form) and
    /// prunes it back to nil when it becomes empty, so the saved map never
    /// accumulates empty (no-op) entries.
    private func updateFocus(org: String, _ mutate: (inout OrgFocusConfig) -> Void) {
        let key = focusKey(org)
        var cfg = settings.reviewFocusByOrg[key] ?? .empty
        mutate(&cfg)
        settings.reviewFocusByOrg[key] = cfg.isEmpty ? nil : cfg
    }

    /// Splits a comma-separated field into trimmed, non-empty tokens.
    private func parseCSV(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Bridges `muteLabels: [String]` to a single comma-separated text field.
    private var muteLabelsBinding: Binding<String> {
        Binding(
            get: { settings.muteLabels.joined(separator: ", ") },
            set: { newValue in
                settings.muteLabels = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    /// Bridges `botAllowList: [String]` to a single comma-separated text field.
    private var botAllowListBinding: Binding<String> {
        Binding(
            get: { settings.botAllowList.joined(separator: ", ") },
            set: { newValue in
                settings.botAllowList = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
