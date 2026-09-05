# Keyboard triage

Mainline is built to run from the keyboard.
Open the panel, then drive the whole deck without touching the mouse.
Every in-panel key is rebindable — see [Customize the shortcuts](#customize-the-shortcuts).

## The default keys

These are the factory bindings.
A key acts on the focused row unless noted.

| Key        | Action           | Notes                                                              |
| ---------- | ---------------- | ----------------------------------------------------------------- |
| `J` / `↓`  | Move down        | Steps to the next PR.                                              |
| `K` / `↑`  | Move up          | Steps to the previous PR.                                         |
| `Space`    | Peek             | Opens the glance card. See [Peek](#peek).                         |
| `↩`        | Open             | Opens the PR in the browser (or Linear — see [Integrations](./integrations.md)). |
| `E`        | Open preview     | Opens the PR's preview deployment. Silent no-op if none.        |
| `N`        | Mark seen        | Clears the unread state.                                          |
| `S`        | Postpone / resume | Postpones with your default duration, or resumes if already postponed. |
| `X`        | Dismiss          | Removes the PR from the view.                                     |
| `M`        | Merge            | Only when the PR is ready to merge. Needs write actions on.       |
| `V`        | Multi-select     | Toggles multi-select mode.                                        |
| `D`        | Toggle drafts    | Shows or hides draft PRs.                                         |
| `Q`        | Mute / move up   | Inbox only. Mutes the PR, or moves a muted PR back up.            |
| `R`        | Refresh          | Refetches now, whether or not a row is focused.                   |
| `⌘Z`       | Undo             | Reverses the last triage action.                                 |

`↩` and `R` work without a focused row.
Every other key acts on the focused row and is a silent no-op when nothing is focused.

## Peek

Press `Space` to open the peek card for the focused PR.
The card shows an instant glance, then loads the changed-files list.

While the card is open:

- `J` / `K` / arrows step through PRs and update the card in place.
- `E` opens the PR's preview deployment.
- `Space` or `Esc` closes the card.

## Postpone and resume

`S` postpones the focused PR with your default duration.
On an already-postponed PR, `S` resumes it.

Set the default duration in **Settings** → **General**.
The row menu and the clock button always offer every duration regardless of the default.

| Duration | Value          |
| -------- | -------------- |
| 1 hour   |                |
| 4 hours  |                |
| 1 day    | Default.       |
| 1 week   |                |

Postponing a PR also mutes its notifications for good — see [Notifications → Postpone mutes notifications](./notifications.md#postpone-mutes-notifications).

## Undo

`⌘Z` reverses the last triage action, including postpone, dismiss, and mark-seen.
Undone actions stack a batched toast so you can see what reverted.

## Approve and request changes

Approve and request changes have no default key.
They live in the row menu — right-click a PR — because they change state on GitHub.
Merge is on the menu too, and also on the `M` key.

All three need write actions turned on.
See [Write actions](./actions.md).

## The row menu

Right-click any PR row to open its menu.
The menu carries every action for that PR — approve, merge, request changes, snooze durations, mark seen, dismiss, view details, open, open preview, and mute.
The "open" item follows your open target, so it reads **Open in Linear** when Linear is configured.

## Global shortcut

A system-wide hotkey opens the Mainline panel from any app.

- Default: `⇧⌃` plus the ISO section key — the physical key left of `1`, which prints `$` on a Danish layout.
- Turn it on or off, record a new combination, or reset it in **Settings** → **Keyboard**.

The recorder shows the current combination as glyphs, such as `⇧⌃⌘P`.

## Customize the shortcuts

Every in-panel key is rebindable in **Settings** → **Keyboard**.

- Each action records a base key plus an optional modifier set — `⌘`, `⇧`, `⌃`, `⌥`.
- Bare keys are allowed, so most actions are a single keystroke.
- Mainline flags a clash when two actions share the same key and modifier set. `E` and `⌘E` are not a clash; two `⌘E` bindings are.
- **Reset All** restores the factory bindings.

New default bindings favor left-hand keys, so you can triage one-handed while your other hand stays on the trackpad.
`J`/`K` navigation and the mnemonic `M`/`N` keys are deliberate exceptions.
