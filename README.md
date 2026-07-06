# Perch

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
git clone https://github.com/yourusername/perch.git
cd perch
xcodebuild -scheme Perch -configuration Debug -destination "platform=macOS" build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/Perch-*/Build/Products/Debug/Perch.app`.

## Setting up a Personal Access Token

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. Create a token with **read** access to your repositories (issues and pull requests)
3. Open Perch Settings and paste the token, or click **Import from gh** if you have [GitHub CLI](https://cli.github.com) installed and authenticated

## Signing & Notarization

> **TODO** — The app currently builds unsigned. To distribute outside of your local machine:
> 1. Set your Apple Developer Team ID in `DEVELOPMENT_TEAM` in the Xcode project settings
> 2. Run `xcodebuild archive` and then `xcrun notarytool submit`
> 3. Staple the notarization ticket with `xcrun stapler staple`

## Screenshots

<!-- TODO: Add screenshots after first working build -->

## Distribution

A Homebrew cask formula is scaffolded at `Homebrew/perch.rb` — update the `url` and `sha256` fields after creating a release.

## License

MIT — see [LICENSE](LICENSE).
