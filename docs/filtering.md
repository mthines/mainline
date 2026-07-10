# Filtering the Inbox

The Inbox tab merges the PRs you opened with the PRs waiting on your review.
That's a lot of PRs, and much of it is automated noise.
The Inbox mute rules demote low-priority PRs into a collapsed group at the bottom, so the active list stays focused.

Nothing is ever hidden.
Muted PRs collapse into a **Muted / low-priority** group you can always expand.
Configure the rules in **Settings** → **Inbox**.

## The four mute rules

A PR is muted by the first rule that matches.
The rules apply in this order.

| # | Rule            | A PR is muted when                                                          | Default              |
| - | --------------- | -------------------------------------------------------------------------- | -------------------- |
| 1 | **Pattern**     | Its title or head branch matches a mute glob.                              | `chore(deps)*`, `build(deps)*` |
| 2 | **Bot author**  | It was opened by dependabot, renovate, github-actions, or any `[bot]` login. | On                 |
| 3 | **Label**       | It carries a label you've muted.                                          | None                 |
| 4 | **Outside focus** | It needs your review but its author or team isn't on your focus list.    | Off (empty list)     |

Rule 4 never mutes your own PRs.
Your created PRs are always active, whatever your focus list says.

### Patterns

Patterns are case-insensitive globs with `*` as the wildcard.
Mainline matches each pattern against both the PR title and the head branch name.
The defaults silence dependency bumps: `chore(deps)*` and `build(deps)*`.

### Bot authors

The bot rule demotes PRs from automated accounts.
It detects dependabot, renovate, and github-actions by name, plus any login ending in `[bot]`.
Turn it off if you review dependency PRs yourself.

### Labels

Add label names to mute PRs that carry them — for example, `dependencies`.
The match is case-insensitive.
An empty list disables label muting.

### Review focus

The focus rule is an allow-list for the **Needs your review** section.
When you fill it in, only PRs from an author or team on the list stay active; everyone else is demoted.

- **Focus authors** — PR author logins to keep active.
- **Focus teams** — team slugs to keep active. A PR is kept if its author or a requested team matches.

Leave both empty for no focus, which keeps every review request active.

## Mute a single PR by hand

Rules cover the common cases.
For one-off decisions, press `Q` on a focused Inbox row.

- `Q` on an active PR mutes it — it drops to the Muted group.
- `Q` on a muted PR pins it back into the active list, even when a rule would mute it.

Manual choices are permanent and always win over the rules.
They're stored per PR and never cleared automatically.
