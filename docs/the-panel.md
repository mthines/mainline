# The panel

The panel is the window that opens when you click the menu bar icon.
It shows the PRs you care about, grouped by what needs you next.
This page explains the tabs, the groups, and the menu bar badge.

## Tabs

The panel has three tabs.
Mainline remembers the last tab you used.

| Tab          | Shows                                                            |
| ------------ | --------------------------------------------------------------- |
| **Inbox**    | A merged view of both queries, filed by role and de-noised.     |
| **For me**   | PRs that request your review or are assigned to you.            |
| **Created**  | PRs you opened.                                                 |

The **Inbox** is the primary tab.
It takes the union of the For me and Created queries, removes duplicates, then applies the mute rules from [Filtering the Inbox](./filtering.md).
It splits the result into two role sections — **Needs your review** and **Your PRs** — and tucks muted PRs into a collapsed **Muted / low-priority** group at the bottom.

The **For me** tab has a sub-filter for how the review was requested.
Set it in **Settings** → **Inbox**.

| Sub-filter | Shows                                    |
| ---------- | ---------------------------------------- |
| **All**    | Direct and team review requests (default). |
| **Direct** | Only requests addressed to you.          |
| **Team**   | Only requests routed through a team.     |

## Actionability groups

Inside a tab, every open PR lands in exactly one group — the first one below that fits.
The group tells you whether the ball is in your court.

| Group             | A PR lands here when                                                       | What to do                          |
| ----------------- | ------------------------------------------------------------------------- | ----------------------------------- |
| **Needs attention** | CI is red, someone requested changes, or there are open review comments. | Fix it — the ball is in your court. |
| **Ready to merge**  | It's approved, mergeable (no conflicts), and CI is green.                | Merge it. Press `M`.                |
| **Waiting**         | CI is still running, or it's not approved, or it's approved but not yet mergeable. | Wait — the ball is elsewhere. |
| **Draft**           | It's a draft, not ready for review.                                       | Nothing yet.                        |
| **Snoozed**         | You postponed it and it hasn't woken.                                     | It steps aside until the timer ends. |
| **Done**            | It recently merged or closed.                                             | Reference only.                     |

The same explanation lives in the app under **Settings** → **Help**.

### The green-check gotcha

A green CI check alone is not "Ready to merge."
A PR with passing CI stays in **Waiting** until it's also approved and conflict-free.
All three conditions together promote it to **Ready to merge**.

### Merge conflicts

By default, a merge conflict shows as an informational tag but does not move a PR into **Needs attention**.
The focus stays on CI health.
To route conflicts into **Needs attention**, turn on `includeConflictsInNeedsHuman` in **Settings**.

## Drafts

Draft PRs are shown by default.
Two independent settings control them, both in **Settings** → **Appearance**.

- **Show drafts** — include drafts in the list, counts, and groups. Press `D` to toggle this quickly.
- **Split drafts** — give shown drafts their own **Draft** group. When off, drafts mix into their real group and stay distinct through a dimmed row and a **Draft** badge.

## Scope filter

The scope filter narrows the panel to a single organization or repository.
Mainline derives the available scopes from your current PR list, so the menu only ever lists orgs and repos you actually have PRs in.

By default the menu bar badge follows the selected scope.
Turn off **Menu bar badge follows scope** in **Settings** → **Menu Bar** to keep the badge counting everything while you filter the panel.

## Menu bar badge

The menu bar icon carries a badge that counts one metric.
Choose the metric in **Settings** → **Menu Bar**.

| Metric            | Counts                                             |
| ----------------- | ------------------------------------------------- |
| **Total Open**    | All open PRs (default).                            |
| **Needs attention** | PRs in the Needs attention group.               |
| **Failing CI**    | Open PRs with failing or errored CI.              |
| **Review Requests** | PRs where you're a requested reviewer.          |
| **Unread**        | PRs you haven't looked at yet.                    |

The icon changes with severity: a neutral dot for a normal count, an orange circle when PRs need attention, and a warning triangle when something is blocking.

## Row density

Rows use a compact single-line layout by default, so more PRs fit on screen.
Turn off **Compact rows** in **Settings** → **Appearance** for a taller two-line layout.

## Panel size

The panel sizes itself to its content and grows up to a maximum.
Set the minimum and maximum content height in **Settings** → **Appearance**.

- Minimum height — the panel never shrinks below this, even with few PRs. Default 600.
- Maximum height — the panel never grows past this, capped to your display. Default 1600.
