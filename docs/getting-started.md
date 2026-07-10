# Getting started

Connect Mainline to GitHub, then take your first look at the panel.
This guide assumes Mainline is already installed.
If it isn't, follow [Install](../README.md#install) first.

## Connect a GitHub token

Mainline reads your pull requests through the GitHub API, so it needs a token.
Pick the option that fits how you already work.

### Import from the GitHub CLI (easiest)

Use this if you have the [GitHub CLI](https://cli.github.com) and have run `gh auth login`.

1. Open Mainline **Settings** → **GitHub**.
2. Click **Import from gh**.

Mainline reuses your existing `gh` token.
That token is already authorized for any SAML SSO organizations you belong to, so org repos work without extra steps.

### Use a personal access token

Use this if you don't have the GitHub CLI.

1. Go to GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)**.
2. Grant the **`repo`** and **`read:org`** scopes.
3. For any PR in an organization that enforces **SAML SSO**, click **Configure SSO** on the token and **authorize** it for that org. Without this, GitHub returns no results for those repos and shows no error.
4. Open Mainline **Settings** → **GitHub** and paste the token.

A fine-grained token with read-only access is usually not enough for org repos.
Prefer a classic token with `repo` + `read:org`, or import from `gh`.

Your token is stored in the macOS Keychain.
It's never written to a plain file or to app preferences.
See [Architecture → Keychain](./architecture.md#keychain) for the storage details.

## Take your first look

Click the menu bar icon to open the panel.
Mainline runs two searches and merges the results:

- PRs you opened — `is:open is:pr author:@me`.
- PRs waiting on your review — `is:open is:pr review-requested:@me`.

The panel opens on the **Inbox** tab, which combines both queries and files each PR by what needs you next.
Read [The panel](./the-panel.md) to learn the tabs and groups.

## Tune the search queries

Change what Mainline watches in **Settings** → **GitHub**.

- `searchQueryAuthor` — PRs you opened. Default `is:open is:pr author:@me`.
- `searchQueryReviewer` — PRs that request your review. Default `is:open is:pr review-requested:@me`.

Both fields accept any [GitHub search syntax](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests).
For example, add `org:acme` to watch a single organization.

## Set how often Mainline checks

Mainline polls GitHub on a timer.
Change the interval in **Settings** → **GitHub**.

- Default: 30 seconds.
- Range: 30 to 3600 seconds.

Polling is conditional — Mainline sends the last `ETag` and GitHub returns `304 Not Modified` when nothing changed, so a steady poll costs almost no rate limit.

## Next steps

- Turn on the notifications you want — [Notifications](./notifications.md).
- Learn the keyboard so you never touch the mouse — [Keyboard triage](./keyboard.md).
- Silence dependency-bump noise in the Inbox — [Filtering the Inbox](./filtering.md).
