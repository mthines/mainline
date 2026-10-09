# Write actions

Write actions let you approve, merge, request changes, close, reopen, and change a PR's draft state without leaving the menu bar.
They change state on GitHub, so they're off by default.

## Turn on write actions

Write actions are disabled until you enable them.

1. Open **Settings** → **GitHub**.
2. Turn on **Enable write actions**.

While write actions are off, `M` (on a ready-to-merge PR) and `T` (on a draft) show a reminder alert instead of acting, and the menu's write items are greyed out.

## The actions

| Action                    | How to trigger                         | Available when                                      |
| ------------------------- | -------------------------------------- | --------------------------------------------------- |
| **Approve**               | Row menu → Approve PR.                 | Any tracked PR.                                     |
| **Request changes**       | Row menu → Request Changes.            | Any tracked PR.                                     |
| **Merge**                 | `M`, or row menu → Merge PR.           | Only when the PR is ready to merge.                 |
| **Mark ready for review** | `T`, or row menu → Mark Ready for Review. | Draft PRs.                                       |
| **Convert to draft**      | Row menu → Convert to Draft.           | Open, non-draft PRs.                                |
| **Close**                 | Row menu → Close PR.                   | Open PRs. Closes without merging.                   |
| **Reopen**                | Row menu → Reopen PR.                  | PRs closed without merging — a pinned closed PR, or a closed PR in **Done**. |

Approve, request changes, convert to draft, close, and reopen have no default key.
They live in the row menu because they change state.
Close has no key on purpose — it is too destructive for a single keystroke.
Merge is on the `M` key and the menu.

`M` acts only when the focused PR is ready to merge — approved, mergeable, and CI green.
On any other PR, `M` does nothing, so it never opens a confirmation for an action that can't run.

GitHub decides who may close, reopen, or convert a PR — usually its author and anyone with write access to the repo.
If GitHub refuses, Mainline shows its error in an alert.

## Confirmation

Approve, request changes, merge, close, and reopen show a confirmation dialog before they call GitHub.
The dialog names the PR and the action.
Press `Return` to confirm, or `Cancel` to back out.

Mark ready and convert to draft act immediately and show a toast instead.
Each reverses the other.

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
