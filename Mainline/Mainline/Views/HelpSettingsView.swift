import SwiftUI

// MARK: - HelpSettingsView

/// Settings detail view for the "Help" category — a plain-language FAQ that
/// explains how Mainline decides which section a PR lands in.
///
/// Wired into `SettingsView` as `SettingsCategory.help`.
///
/// The explanations here mirror the real decision logic:
///  - Role-aware actionability grouping — `PRSnapshot.actionGroup(splitDrafts:myLogin:reviewReady:)`.
///    Your PRs use Needs attention / Ready to merge / Waiting; PRs you were asked
///    to review use Ready for review / Waiting.
///  - Inbox mute rules — `InboxMuteEngine.muteVerdict(...)`
///    (Muted / low-priority).
///
/// Keep the copy short and correlated to what the user actually sees in the
/// deck. If the logic changes, update the copy here so the FAQ stays honest.
struct HelpSettingsView: View {
    var body: some View {
        Section {
            Text("Sections mean different things for your PRs versus PRs you were asked to review. The goal is the same: show what needs your time now, and let the rest wait.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Your PRs") {
            FAQItem(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Needs attention",
                blurb: "The ball is in your court. Lands here if any of:",
                bullets: [
                    "CI is red (failing)",
                    "Someone requested changes",
                    "There are open review comments to resolve",
                    "It has merge conflicts to rebase"
                ],
                youSee: "The top group. Look for the red \"changes\" badge, a 💬 comment count, or a conflict flag."
            )

            FAQItem(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "Ready to merge",
                blurb: "Nothing left but the merge button. Needs all three:",
                bullets: [
                    "Approved",
                    "No conflicts (mergeable)",
                    "CI is green"
                ],
                youSee: "Only appears once a PR is fully cleared. Hit M to merge."
            )

            FAQItem(
                icon: "clock.fill",
                tint: .secondary,
                title: "Waiting",
                blurb: "Not on you — waiting on reviewers or CI:",
                bullets: [
                    "CI still running",
                    "Not approved yet"
                ],
                youSee: "A green ✓ shows CI passed — but it's still waiting on a review."
            )
        }

        Section("PRs you were asked to review") {
            FAQItem(
                icon: "eye.fill",
                tint: .orange,
                title: "Ready for review",
                blurb: "Genuinely ready for your eyes — none of the \"author still owns it\" signals fire.",
                youSee: "The top group. These are the ones worth your review time right now."
            )
            FAQItem(
                icon: "clock.fill",
                tint: .secondary,
                title: "Waiting",
                blurb: "The author still owns it, so reviewing now is premature. Lands here if any of:",
                bullets: [
                    "Merge conflicts",
                    "Failing CI",
                    "Unresolved comment threads",
                    "You already approved it"
                ],
                youSee: "Pick which signals count in Settings › Inbox › Review Readiness. All on by default."
            )
        }

        Section("Two more sections") {
            FAQItem(
                icon: "pencil.and.outline",
                tint: .secondary,
                title: "Draft",
                blurb: "Work in progress, not ready for review.",
                youSee: "Its own group (or a dimmed \"Draft\" badge inline)."
            )
            FAQItem(
                icon: "moon.zzz.fill",
                tint: .secondary,
                title: "Snoozed",
                blurb: "You pressed S to deal with it later.",
                youSee: "A \"Later\" badge; it steps aside until the snooze ends."
            )
        }

        Section("Muted / low-priority — Inbox only") {
            Text("The Inbox tucks noisy PRs into a collapsed group at the very bottom. A PR is muted by the first rule that matches:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FAQItem(
                icon: "text.magnifyingglass",
                tint: .secondary,
                title: "Matches a pattern",
                blurb: "Title or branch matches a mute pattern (e.g. chore(deps)*)."
            )
            FAQItem(
                icon: "gearshape.2.fill",
                tint: .secondary,
                title: "From a bot",
                blurb: "Opened by dependabot, renovate, or any [bot] account."
            )
            FAQItem(
                icon: "tag.fill",
                tint: .secondary,
                title: "Has a muted label",
                blurb: "Carries a label you've muted (e.g. dependencies)."
            )
            FAQItem(
                icon: "person.2.slash.fill",
                tint: .secondary,
                title: "Outside your focus",
                blurb: "Needs your review but the author/team isn't on your focus list. Your own PRs are never muted this way."
            )

            Label(
                "Set all of these in Settings › Inbox. Nothing is hidden — the Muted group is always there to expand.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - FAQItem

/// One labelled explanation row: a tinted SF Symbol, a bold title, a one-line
/// blurb, an optional bullet list of the exact conditions, and an optional
/// "you see" line that ties it back to what appears in the deck.
private struct FAQItem: View {
    let icon: String
    let tint: Color
    let title: String
    let blurb: String
    var bullets: [String] = []
    var youSee: String? = nil

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

                if let youSee {
                    Label(youSee, systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
