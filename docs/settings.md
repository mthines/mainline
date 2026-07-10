# Settings reference

Every setting Mainline exposes, grouped by its pane in the Settings window.
Open Settings from the panel or with the standard `⌘,` shortcut.

The panes are **GitHub**, **Notifications**, **Inbox**, **Menu Bar**, **Appearance**, **Keyboard**, **Privacy**, and **Help**.

## GitHub

Token, queries, polling, and write actions.

| Setting               | Default                            | Notes                                                    |
| --------------------- | ---------------------------------- | ------------------------------------------------------- |
| GitHub token          | —                                  | Stored in the Keychain. Paste it or import from `gh`.   |
| Author query          | `is:open is:pr author:@me`         | PRs you opened.                                          |
| Reviewer query        | `is:open is:pr review-requested:@me` | PRs that request your review.                          |
| Poll interval         | 30 s                               | Range 30–3600 s.                                         |
| Enable write actions  | Off                                | Gates approve, merge, and request changes.              |
| Merge method          | Auto                               | Auto, squash, merge commit, or rebase. See [Write actions](./actions.md). |
| Open target           | GitHub                             | GitHub or Linear. See [Integrations](./integrations.md). |
| Linear repo filter    | Empty (all repos)                  | Allow-list of `owner` or `owner/repo` entries.          |
| Default snooze duration | 1 day                            | Used by the `S` key.                                     |

## Notifications

Which events notify you, and how loudly.
See [Notifications](./notifications.md) for the full model.

| Setting               | Default | Notes                                              |
| --------------------- | ------- | ------------------------------------------------- |
| New PR                | On      | Fires when a new PR matches a query.              |
| Ready for review      | On      | Draft becomes ready, or you're added as reviewer. |
| CI status changed     | On      | CI passes or fails.                               |
| New review or comment | On      | A review or comment lands.                         |
| Only human comments   | On      | Ignores bot and app comments.                     |
| Attention level       | Per event | Notify or quiet, set per event.                 |

## Inbox

The four mute rules and the review-focus allow-list.
See [Filtering the Inbox](./filtering.md).

| Setting          | Default                          | Notes                                            |
| ---------------- | ------------------------------- | ----------------------------------------------- |
| Mute patterns    | `chore(deps)*`, `build(deps)*`  | Globs matched against title and branch.         |
| Mute bot authors | On                              | Demotes dependabot, renovate, and `[bot]` logins. |
| Mute labels      | Empty                           | Label names that demote a PR.                    |
| Focus authors    | Empty                           | Allow-list of author logins for review.          |
| Focus teams      | Empty                           | Allow-list of team slugs for review.             |

## Menu Bar

What the badge counts and whether it follows the scope filter.
See [The panel → Menu bar badge](./the-panel.md#menu-bar-badge).

| Setting                     | Default    | Notes                                              |
| --------------------------- | ---------- | ------------------------------------------------- |
| Badge metric                | Total Open | Total Open, Needs attention, Failing CI, Review Requests, or Unread. |
| Badge follows scope         | On         | Off keeps the badge counting everything.          |

## Appearance

Density, drafts, and panel size.
See [The panel](./the-panel.md).

| Setting                | Default | Notes                                                    |
| ---------------------- | ------- | ------------------------------------------------------- |
| Compact rows           | On      | Off uses a taller two-line row.                          |
| Show drafts            | On      | Include drafts in the list and counts. `D` toggles it.  |
| Split drafts           | Off     | Give shown drafts their own group.                       |
| Conflicts need a human | Off     | Route merge conflicts into Needs attention.             |
| Minimum panel height   | 600     | The panel never shrinks below this.                     |
| Maximum panel height   | 1600    | The panel never grows past this, capped to the display. |

## Keyboard

The global shortcut and the in-panel key bindings.
See [Keyboard triage](./keyboard.md).

| Setting            | Default                     | Notes                                            |
| ------------------ | --------------------------- | ----------------------------------------------- |
| Global shortcut    | On, `⇧⌃` + ISO section key  | System-wide hotkey to open the panel.           |
| In-panel bindings  | Factory defaults            | Rebind each action; **Reset All** restores them. |

## Privacy

Anonymous telemetry, off by default.
See [Telemetry](./telemetry.md).

| Setting                    | Default | Notes                                    |
| -------------------------- | ------- | --------------------------------------- |
| Share anonymous usage data | Off     | Opt-in. No PR content ever leaves the app. |

## Help

A read-only FAQ.
It explains how Mainline decides which group a PR lands in.
The same logic is documented in [The panel](./the-panel.md).

## Where settings are stored

Non-secret settings live in macOS `UserDefaults` under the `com.mainline.github-pr-notifier` bundle.
Your GitHub token is the one exception — it's stored in the Keychain, never in `UserDefaults`.
For the full list of `UserDefaults` keys and their types, see [`../CLAUDE.md`](../CLAUDE.md#userdefaults-keys).
