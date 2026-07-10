import SwiftUI

// MARK: - HelpSettingsView

/// Settings detail view for the "Help" category — a plain-language FAQ that
/// explains how Mainline decides which section a PR lands in.
///
/// Wired into `SettingsView` as `SettingsCategory.help`.
///
/// The explanations here mirror the real decision logic:
///  - Actionability grouping — `PRSnapshot.actionGroup(splitDrafts:)`
///    (Needs attention / Ready to merge / Waiting / Draft).
///  - Inbox mute rules — `InboxMuteEngine.muteVerdict(...)`
///    (Muted / low-priority).
///
/// If that logic changes, update the copy here so the FAQ stays honest.
struct HelpSettingsView: View {
    var body: some View {
        Section {
            Text("Every open PR is sorted into exactly one section, based on the first rule below that matches. This is how Mainline decides what needs you now versus what can wait.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("How PRs are grouped") {
            FAQItem(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Needs attention",
                blurb: "The PR is blocked and there's something you can act on. A PR lands here if any of these are true:",
                bullets: [
                    "CI is failing or errored",
                    "A reviewer requested changes",
                    "There are unresolved review threads (open conversations)"
                ]
            )

            FAQItem(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "Ready to merge",
                blurb: "Everything is clear — the only thing left is to merge. This requires all three at once:",
                bullets: [
                    "The PR is approved",
                    "GitHub reports it mergeable (no conflicts)",
                    "CI has passed"
                ]
            )

            FAQItem(
                icon: "clock.fill",
                tint: .secondary,
                title: "Waiting",
                blurb: "Everything else that's open. The PR isn't blocked on you, but it isn't fully clear to merge either — it's waiting on someone or something else. Typically:",
                bullets: [
                    "CI is still running",
                    "It hasn't been approved yet",
                    "It's approved but not yet mergeable"
                ]
            )
        }

        Section("A common surprise") {
            Label(
                "A green CI check by itself does NOT mean \"Ready to merge.\" A PR with passing CI still sits in Waiting until it's also approved AND mergeable. Approval + mergeable + green CI together are what promote it.",
                systemImage: "lightbulb.fill"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Section("Drafts") {
            Label(
                "Draft PRs are shown in their own \"Draft\" section when \"split drafts\" is enabled. Otherwise a draft mixes into whichever group its signals imply, marked with a Draft badge and dimmed.",
                systemImage: "pencil.and.outline"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Section("Snoozed ('Later')") {
            Label(
                "Pressing S (or choosing Later) snoozes a PR. It shows a \"Later\" badge and drops out of the active groups until its snooze expires, so it stops competing for your attention in the meantime.",
                systemImage: "moon.zzz.fill"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Section("Muted / low-priority (Inbox only)") {
            Text("Separate from actionability, the Inbox demotes noisy PRs into a collapsed \"Muted / low-priority\" group at the bottom. A PR is muted by the first of these rules that matches:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FAQItem(
                icon: "text.magnifyingglass",
                tint: .secondary,
                title: "Title / branch pattern",
                blurb: "Its title or head branch matches one of your mute glob patterns (e.g. chore(deps)*)."
            )
            FAQItem(
                icon: "gearshape.2.fill",
                tint: .secondary,
                title: "Bot author",
                blurb: "It was opened by a bot (login ending in [bot], or a known dependency bot like dependabot / renovate) and \"Mute bot-authored PRs\" is on."
            )
            FAQItem(
                icon: "tag.fill",
                tint: .secondary,
                title: "Label",
                blurb: "It carries one of your muted labels (e.g. dependencies, automated)."
            )
            FAQItem(
                icon: "person.2.slash.fill",
                tint: .secondary,
                title: "Outside review focus",
                blurb: "When a review-focus allow-list is set, a PR needing your review whose author (or requested team) isn't on the list is muted. Your own PRs are never muted by focus."
            )

            Label(
                "Configure all of these in Settings › Inbox. Muting only reorders and collapses — nothing is hidden, and you can always expand the Muted group.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - FAQItem

/// One labelled explanation row: a tinted SF Symbol, a bold title, a short
/// blurb, and an optional bullet list of the exact conditions.
private struct FAQItem: View {
    let icon: String
    let tint: Color
    let title: String
    let blurb: String
    var bullets: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.body)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))

                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(bullets, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(bullet)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
