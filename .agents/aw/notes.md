# Repo facts — mthines/mainline

- Native macOS menu-bar app (Swift/SwiftUI, Xcode project at root). No browser surface: ui-verify / aw-tester do not apply.
- Build: `xcodebuild -scheme Mainline -configuration Debug -destination "platform=macOS" build` (add `CODE_SIGNING_ALLOWED=NO` locally).
- Dev loop: `pnpm run dev` (nx → scripts/dev.sh; requires `brew install fswatch`). Process name: `Mainline`.
- No XCTest target. Tests are `#if DEBUG` self-check functions on pure types, run from `AppDelegate.applicationDidFinishLaunching`; a failed assertion shows up at launch in a Debug build.
- Auth: GitHub PAT in the Keychain (service `com.mainline.github-pr-notifier` per CLAUDE.md), read once per launch; first read after re-signing may raise a Keychain prompt.
- Telemetry is opt-in (default OFF): enable in Settings → Privacy; build needs `DASH0_AUTH_TOKEN` and `OTEL_EXPORTER_OTLP_ENDPOINT` in the environment. Service name `mainline`. Never put PR titles/repos/logins in signals.
- Telemetry server: `.mcp.json` `dash0-dev` (personal key in ~/.agents/aw/config.yml); dataset unconfirmed.
- Ship via branch → /create-pr → /review-loop --merge; never push directly to main (each merge is a release).
