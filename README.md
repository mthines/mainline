# Mainline

A lightweight macOS menu bar app that keeps you on top of your GitHub pull requests.

[![CI](https://github.com/mthines/mainline/actions/workflows/ci.yml/badge.svg)](https://github.com/mthines/mainline/actions/workflows/ci.yml)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<img width="406" height="588" alt="Mainline menu bar panel showing PRs grouped by actionability" src="https://github.com/user-attachments/assets/0b1661ac-4dc7-48e3-a999-9d3a48e5a26c" />

Mainline lives in your menu bar and watches the pull requests you care about — the ones you opened and the ones waiting on your review.
It notifies you when something changes: a PR turns green, a review lands, or CI breaks.
It groups every PR by what needs your attention, and lets you approve, merge, or snooze straight from the keyboard.
No browser tabs, no refreshing GitHub by hand.

**Jump to:** [Install](#install) · [Get started](#get-started) · [Features](#features) · [Screenshots](#screenshots)

## Install

Mainline is distributed through a Homebrew tap.

```bash
brew tap mthines/mainline
brew install --cask mainline
```

Then open Mainline from Spotlight or your Applications folder.
A menu bar icon appears — click it to open the panel.

<details>
<summary>Install a beta build</summary>

Beta builds are published for every non-draft pull request.

```bash
brew tap mthines/mainline

# Latest beta
brew install --cask --force mthines/mainline/mainline-beta

# A specific pinned beta version
brew install --cask --force mthines/mainline/mainline-beta@1.2.3-beta.42.1
```

`--force` is required because beta and stable share `/Applications/Mainline.app`.
To roll back to stable: `brew install --cask --force mthines/mainline/mainline`.

</details>

**Requirements:** macOS 13 Ventura or later, and a GitHub account.

## Get started

Mainline needs a GitHub token to read your pull requests.
Pick whichever option fits how you already work.

### Import from the GitHub CLI (easiest)

If you use the [GitHub CLI](https://cli.github.com) and have run `gh auth login`, open Mainline **Settings** and click **Import from gh**.
Mainline reuses your existing `gh` token, which is already authorized for any SAML SSO organizations you belong to.

### Use a personal access token

1. Go to GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)**.
2. Grant the **`repo`** and **`read:org`** scopes.
3. If any of your PRs live in an organization that enforces **SAML SSO**, click **Configure SSO** on the token and **authorize** it for that org — otherwise GitHub silently returns *no results* for those repos.
4. Open Mainline **Settings** and paste the token.

> **Note:** a fine-grained token with only "read" access is usually **not** enough for org repos.
> Prefer a classic token with `repo` + `read:org`, or use *Import from gh*.

Your token is stored in the macOS Keychain — never in a plain file or in app preferences.

## Features

### Stay notified

- **New PR** — fires a notification when a new PR appears in your search queries.
- **Ready for review** — notifies when a draft PR becomes ready, or when you're added as a reviewer.
- **CI status changed** — fires when CI passes or fails on any tracked PR.
- **New review or comment** — notifies when a review or comment is added (human comments only, by default — bot noise is filtered).
- **Per-event attention levels** — set each event type to a loud or quiet notification independently.

### Triage fast

- **Menu bar panel** — click the icon to see your PRs grouped by actionability (Needs a Human, Ready to merge, Waiting, …), each with CI status.
- **Keyboard triage** — drive the whole panel from the keyboard: `J`/`K` to move, `Space` to preview the diff, `A`/`M`/`R` to approve / merge / request changes, `S` to snooze, `E` to mark seen, `X` to dismiss, `V` for multi-select, `⌘Z` to undo.
- **Command palette** — `⌘K` opens a Raycast-style palette for every action.
- **Diff preview** — `Space` shows the PR diff inline via Quick Look.
- **Global shortcut** — open Mainline from any app with a system-wide hotkey (default ⇧⌃ + the key left of `1`; customizable in Settings).
- **Scope filter** — narrow the panel and badge to a single org or repo.
- **Trust ledger** — tracks how each author's PRs have turned out, surfaced as a compact tier badge per row.

### Act (optional, off by default)

- **Write actions** — approve, merge, or request changes without leaving the menu bar (each behind a confirmation; enable in Settings).
- **Autopilot** — auto-approve trusted, low-risk PRs (requires write actions to be enabled).

### Configure and secure

- **Configurable polling** — default 60s interval; adjustable in Settings (30s – 3600s).
- **Custom search queries** — default `is:open is:pr author:@me` and `is:open is:pr review-requested:@me`.
- **Keychain storage** — your token is stored securely in the macOS Keychain; never in app preferences or on disk.
- **Opt-in telemetry** — anonymous usage data is **off** by default; enable it in Settings → Privacy (see [`docs/telemetry.md`](docs/telemetry.md)).

## Screenshots

### Settings

<img width="1136" height="917" alt="Mainline Settings window showing token import, notification toggles, and the global shortcut recorder" src="https://github.com/user-attachments/assets/7bd80ef7-ee9e-4feb-a17f-b3100e3c2f85" />

## For developers

Mainline is a native SwiftUI app. To build it from source:

```bash
git clone https://github.com/mthines/mainline.git
cd mainline
xcodebuild -scheme Mainline -configuration Debug -destination "platform=macOS" build
```

The built app lands in `~/Library/Developer/Xcode/DerivedData/Mainline-*/Build/Products/Debug/Mainline.app`.
Building requires **Xcode 15+**.

Releases run automatically through GitHub Actions: a push to `main` publishes a stable build, and a non-draft pull request publishes a beta.
For code signing, notarization, the release pipeline, and Homebrew tap internals, see [`docs/release.md`](docs/release.md).

## License

MIT — see [LICENSE](LICENSE).
