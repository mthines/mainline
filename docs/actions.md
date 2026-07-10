# Write actions

Write actions let you approve, merge, and request changes on a PR without leaving the menu bar.
They change state on GitHub, so they're off by default and every one asks for confirmation.

## Turn on write actions

Write actions are disabled until you enable them.

1. Open **Settings** → **GitHub**.
2. Turn on **Enable write actions**.

While write actions are off, `M` and the menu's write items show a reminder alert instead of acting.

## The three actions

| Action              | How to trigger                        | Available when                              |
| ------------------- | ------------------------------------- | ------------------------------------------- |
| **Approve**         | Row menu → Approve PR.                | Any tracked PR.                             |
| **Request changes** | Row menu → Request Changes.           | Any tracked PR.                             |
| **Merge**           | `M`, or row menu → Merge PR.          | Only when the PR is ready to merge.         |

Approve and request changes have no default key.
They live in the row menu because they change state.
Merge is on the `M` key and the menu.

`M` acts only when the focused PR is ready to merge — approved, mergeable, and CI green.
On any other PR, `M` does nothing, so it never opens a confirmation for an action that can't run.

## Confirmation

Every write action shows a confirmation dialog before it calls GitHub.
The dialog names the PR and the action.
Press `Return` to confirm, or `Cancel` to back out.

The confirmation is a native app-modal alert, not an in-panel dialog.
This keeps the action alive even though acting normally closes the popover.

## Merge method

Set your preferred merge method in **Settings** → **GitHub**.

| Method          | Behavior                                                            |
| --------------- | ------------------------------------------------------------------ |
| **Auto**        | Uses the repo's allowed method — squash, then rebase, then merge. Default. |
| **Squash**      | Requests a squash merge, falling back to the auto order if the repo forbids it. |
| **Merge commit** | Requests a merge commit, with the same fallback.                  |
| **Rebase**      | Requests a rebase merge, with the same fallback.                   |

Auto is the safe choice — it always picks a method the repo permits.
