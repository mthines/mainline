# Release pipeline

This document covers the Mainline release automation: the trigger model, required secrets,
one-time tap setup, and optional signing and notarization.

## Trigger model

| Event | Result |
|-------|--------|
| `push` to `main` (feat/fix/etc commit) | Stable release: bumps `Info.plist`, creates `chore(release):` commit, creates annotated tag `vX.Y.Z`, publishes GitHub release, updates Homebrew tap |
| Non-draft pull request (opened, sync, ready) | Beta release: creates annotated tag `vX.Y.Z-beta.{PR#}.{n}`, publishes pre-release on GitHub, comments install instructions on the PR |
| `workflow_dispatch` from `main` | Stable release (same as push) |
| `workflow_dispatch` from a branch with an open PR | Beta release (same as PR trigger) |

### Loop-skip guard

Commits whose message matches `^chore(release):` or `^feat(cask):` do **not** re-trigger
a release. This prevents the version-bump commit from starting another release cycle.

### Draft PRs

Draft pull requests are detected and skipped (`should_release=false`). Mark the PR as
"ready for review" to trigger a beta build.

## One-time setup: Homebrew tap

Before the first release, create the `mthines/homebrew-mainline` tap repository and
populate it locally:

```bash
# From the repo root
pnpm setup-tap
# or
bash scripts/setup-tap.sh
```

Then follow the printed instructions:
1. Create a public GitHub repository named `homebrew-mainline` under the `mthines` account.
2. Push the local tap to that repository.
3. Add the `HOMEBREW_TAP_TOKEN` secret (see below).

After the tap is live, users install Mainline with:

```bash
brew tap mthines/mainline
brew install --cask mainline
```

## Required GitHub secrets

Add these in **Settings → Secrets and variables → Actions → Secrets** of the
`mthines/mainline` repository.

| Secret | Description |
|--------|-------------|
| `DASH0_AUTH_TOKEN` | Dash0 auth token embedded into the Release build for telemetry. The release build still succeeds without it (a warning is logged), but no telemetry will be sent. |
| `HOMEBREW_TAP_TOKEN` | Personal Access Token with `repo` scope on the `mthines/homebrew-mainline` repository. Without this, the tap update step is skipped (release still publishes to GitHub). |

### Optional secret: GH_PAT

If `main` has branch protection rules that block the `GITHUB_TOKEN` bot from pushing
(e.g. required reviews), add:

| Secret | Description |
|--------|-------------|
| `GH_PAT` | Personal Access Token with `repo` scope on `mthines/mainline`. Used by the `version` job to push the `chore(release):` commit and the `release-macos` job to sync the cask back to `main`. Without it the workflow falls back to `GITHUB_TOKEN`; if that token is blocked by branch protection the version job will fail. |

## Repository variable (not a secret)

Add this in **Settings → Secrets and variables → Actions → Variables**:

| Variable | Description |
|----------|-------------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP/HTTP endpoint URL for telemetry (e.g. `https://ingress.us-east-1.dash0.com`). Not sensitive — passed to `xcodebuild` via `vars.OTEL_EXPORTER_OTLP_ENDPOINT`. |

## Optional: Developer ID signing and notarization

Without signing secrets the release pipeline builds an **unsigned** app. Unsigned apps
are quarantined by Gatekeeper on download; the Homebrew cask removes the quarantine
attribute via `xattr -cr` in its `preflight` block so installation via `brew install`
is transparent to users. Direct downloads require the user to right-click → Open once.

To ship a signed and notarized app, add the following secrets:

| Secret | Description |
|--------|-------------|
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application certificate + private key in PKCS#12 format. Export from Keychain Access: Certificate → Export → .p12, then `base64 -i cert.p12`. |
| `MACOS_CERTIFICATE_PASSWORD` | Password set when exporting the P12. |
| `NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect API key (.p8 file) for `notarytool`. Generate in App Store Connect → Users and Access → Keys. |
| `NOTARY_KEY_ID` | Key ID shown in App Store Connect (10-character string). |
| `NOTARY_ISSUER_ID` | Issuer ID shown in App Store Connect → Keys (UUID format). |

### Obtaining the Developer ID certificate

1. Open Xcode → Settings → Accounts → Manage Certificates.
2. Click **+** and choose **Developer ID Application**.
3. Export from Keychain Access → My Certificates → right-click → Export.
4. Encode: `base64 -i DeveloperIDApplication.p12 | pbcopy`.

### Obtaining the notary API key

1. App Store Connect → Users and Access → Keys tab.
2. Generate a new key with **Developer** role (or **Admin** if that is unavailable).
3. Download the `.p8` file (available once; store securely).
4. Encode: `base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy`.

When all five signing secrets are present, `release-ci.sh` will:
1. Import the certificate into a temporary keychain.
2. Sign `Mainline.app` and any embedded frameworks with `--options runtime --timestamp`.
3. Submit to Apple's notary service and wait up to 30 minutes.
4. Staple the notarization ticket so Gatekeeper accepts the app offline.
5. Re-zip the stapled bundle so the published archive's SHA256 matches the notarized binary.

## Local release

To cut a release from your local machine (for testing the pipeline without CI):

```bash
pnpm release
# or
bash scripts/release.sh
```

The script reads `~/.config/mainline/.env` for `DASH0_AUTH_TOKEN` and
`OTEL_EXPORTER_OTLP_ENDPOINT`, bumps the version, builds, zips, updates the cask, and
pushes to GitHub. It requires `gh` CLI and a tap checked out locally (run
`pnpm setup-tap` first).

## Cask maintenance

The in-repo cask at `Casks/mainline.rb` is the **source of truth** for the stable cask
shape (description, depends_on, uninstall, zap). On every stable release, `release-ci.sh`
copies this file to the tap and patches `version` and `sha256` via `sed`.

To change the cask (e.g. add a `caveats` block or update the `zap` paths), edit
`Casks/mainline.rb` directly. The change will propagate to the tap on the next release.

The beta cask (`Casks/mainline-beta.rb`) is a documentation template only; `release-ci.sh`
generates the actual beta cask by copying the stable source and patching the cask name,
version, and sha256.
