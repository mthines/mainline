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
            TextField(
                "Focus authors",
                text: reviewFocusAuthorsBinding,
                prompt: Text("alice, bob")
            )
            .textFieldStyle(.roundedBorder)
            Label("Comma-separated GitHub logins. When non-empty, only PRs authored by someone on this list (or a team in Focus Teams) stay active in \"Needs your review\". Empty = show all.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "Focus teams",
                text: reviewFocusTeamsBinding,
                prompt: Text("platform, frontend")
            )
            .textFieldStyle(.roundedBorder)
            Label("Comma-separated team slugs. Works alongside Focus Authors — a PR is kept if its author OR a requested team matches. Empty = show all.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// Bridges `reviewFocusAuthors: [String]` to a single comma-separated text field.
    private var reviewFocusAuthorsBinding: Binding<String> {
        Binding(
            get: { settings.reviewFocusAuthors.joined(separator: ", ") },
            set: { newValue in
                settings.reviewFocusAuthors = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    /// Bridges `reviewFocusTeams: [String]` to a single comma-separated text field.
    private var reviewFocusTeamsBinding: Binding<String> {
        Binding(
            get: { settings.reviewFocusTeams.joined(separator: ", ") },
            set: { newValue in
                settings.reviewFocusTeams = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
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
