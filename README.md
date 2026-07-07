# Mainline

A lightweight macOS menu bar app that notifies you about GitHub pull requests.

## Features

- **New PR** — fires a notification when a new PR appears in your search queries
- **Ready for Review** — notifies when a draft PR becomes ready, or when you're added as a reviewer
- **CI Status Changed** — fires when CI passes or fails on any tracked PR
- **New Review / Comment** — notifies when a review or comment is added
- **Menu bar dropdown** — click the bird icon to see open PRs with CI status indicators; click any row to open the PR in your browser
- **Configurable polling** — default 60s interval; adjustable in Settings (30s – 3600s)
- **Custom search queries** — default `is:open is:pr author:@me` and `is:open is:pr review-requested:@me`
- **Per-event notification toggles** — enable or disable each notification type independently
- **Keychain storage** — your PAT is stored securely in the macOS Keychain; never in UserDefaults or on disk
- **Import from gh CLI** — click "Import from gh" to automatically pull your token from `gh auth token`

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (to build from source)
- A GitHub Personal Access Token with `repo` scope (or `read:org` + `repo` for org-wide visibility)

## Building from Source

```bash
git clone https://github.com/mthines/mainline.git
cd mainline
xcodebuild -scheme Mainline -configuration Debug -destination "platform=macOS" build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/Mainline-*/Build/Products/Debug/Mainline.app`.

## Authentication

The easiest option is **Import from gh**: if you have the [GitHub CLI](https://cli.github.com)
installed and authenticated (`gh auth login`), open Mainline Settings and click
**Import from gh**. This reuses your `gh` token, which is already authorized for any
SSO-protected organizations you belong to.

To use a Personal Access Token instead:

1. GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)**
2. Grant the **`repo`** and **`read:org`** scopes
3. If any of your PRs live in an organization that enforces **SAML SSO**, click
   **Configure SSO** on the token and **authorize** it for that org — otherwise GitHub
   silently returns *no results* for those repos
4. Open Mainline Settings and paste the token

> **Note:** a fine-grained token with only "read" access is usually **not** enough for
> org repos — prefer a classic token with `repo` + `read:org`, or just use *Import from gh*.

## Signing & Notarization

Debug builds are signed automatically with your **Apple Development** identity — set your
own Team ID in `DEVELOPMENT_TEAM` (Xcode → target → Signing & Capabilities, or the
`project.pbxproj` build settings). A stable signing identity is required for consistent
Keychain access across rebuilds; ad-hoc signing causes repeated Keychain prompts.

To distribute outside your machine:

1. Build with your **Developer ID Application** identity
2. `xcodebuild archive` → `xcrun notarytool submit` → `xcrun stapler staple`

## Screenshots

<!-- TODO: Add screenshots after first working build -->

## Releasing / Homebrew

Mainline is distributed via a Homebrew tap at `mthines/homebrew-mainline`.

### Install (stable)

```bash
brew tap mthines/mainline
brew install --cask mainline
```

### Install (beta)

Beta builds are published for every non-draft pull request.

```bash
brew tap mthines/mainline

# Latest beta
brew install --cask --force mthines/mainline/mainline-beta

# A specific pinned beta version
brew install --cask --force mthines/mainline/mainline-beta@1.2.3-beta.42.1
```

> `--force` is required because beta and stable share `/Applications/Mainline.app`.
> To roll back to stable: `brew install --cask --force mthines/mainline/mainline`.

### Release automation

Releases are fully automated via GitHub Actions (`.github/workflows/ci.yml`):

- Push to `main` → stable release
- Non-draft PR → beta release (tagged, published, PR comment with install instructions)
- `workflow_dispatch` → manual trigger (stable from `main`, beta from a branch with open PR)

See [`docs/release.md`](docs/release.md) for required secrets, one-time tap setup, and
optional signing/notarization.

## Distribution

The Homebrew cask lives at `Casks/mainline.rb` (stable) and `Casks/mainline-beta.rb`
(beta template). Both are updated automatically by the release pipeline.

## License

MIT — see [LICENSE](LICENSE).
