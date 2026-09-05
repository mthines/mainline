# Architecture

This page explains how Mainline is built and why.
It's for contributors.
The prescriptive rules an agent needs on every turn live in [`../CLAUDE.md`](../CLAUDE.md) — this doc covers the reasoning behind them.

Mainline is a native SwiftUI menu bar app.
It targets macOS 13, which is why it uses `MenuBarExtra` and avoids APIs added later.

## The big picture

Mainline polls GitHub on a timer, diffs each result against the last one, and turns the differences into notifications and UI state.

```
GitHubClient  →  PRPoller  →  PRStateStore  →  PRDiffEngine  →  transitions
   (I/O)          (loop)       (state)          (pure)              │
                                                                    ▼
                                          NotificationService + PRManager (UI)
```

Every source file must appear in three places inside `Mainline.xcodeproj/project.pbxproj` — the file reference, the build file, and the sources build phase.
Miss one and the build breaks with no clear error.

## Layered by side effects

The codebase splits sharply between pure logic and impure shells.
Pure code is testable without mocks; impure code owns I/O and state.

| Layer            | Files                                                      | Nature                          |
| ---------------- | --------------------------------------------------------- | ------------------------------- |
| **Pure logic**   | `PRDiffEngine`, `TriageClassifier`, `SensitivePathMatcher`, `InboxMuteEngine`, `PROpenTarget` | No I/O — deterministic and unit-testable. |
| **State shells** | `PRStateStore`, `SnoozeStore`, `ScopeStore`               | Own their persistence.          |
| **I/O shells**   | `GitHubClient`, `KeychainHelper`, `NotificationService`, `TelemetryService` | Talk to the network, Keychain, and system services. |
| **Orchestration**| `PRManager`, `PRPoller`                                   | Wire the layers together.       |

## State ownership

All PR state lives in `PRStateStore`, a `@MainActor` dictionary keyed by node ID.
`PRPoller` never writes snapshots directly.
It calls `PRStateStore.update(new:myLogin:)`, which runs the diff engine and returns the transitions.
One owner means state can't drift between the poller and the UI.

## The diff engine

`PRDiffEngine.diff(previous:next:myLogin:)` is the heart of the app.
It's pure: given the old and new snapshots, it returns one of a small set of transitions.
Those transitions drive both notifications and the actionability grouping.

Some fields deliberately don't trigger a transition.
Labels, the bot-author flag, and the preview URL are excluded, so enriching a PR with a preview never fires a spurious "new PR" banner.

## Notifications

`NotificationService` builds one `UNNotificationRequest` per transition.
IDs are deterministic — `mainline.new_pr.<nodeId>` — so a rapid second poll replaces the banner instead of stacking a duplicate.

The attention policy (`AttentionPolicy`) maps each event to notify or quiet.
See [Notifications](./notifications.md) for the user-facing view.

## Threading

`PRManager`, `PRPoller`, `PRStateStore`, and `SnoozeStore` all run on the main actor.
Background work — Keychain reads, `URLSession`, JSON on disk — runs in `Task.detached` and bridges back across the async boundary.

## Keychain

`KeychainHelper` is async-only.
It never blocks the main actor: `loadToken()` runs its work in `Task.detached` internally.

- Service: `com.mainline.github-pr-notifier`
- Account: `github-pat`
- Class: `kSecClassGenericPassword`

The app is not sandboxed.
That's what enables outbound network access, Keychain access, and the `gh` subprocess used by token import.

## Keyboard events in a menu bar popover

Driving the panel from the keyboard is harder than it looks on macOS 13.

`onKeyPress` needs macOS 14.
A local `NSEvent` monitor only fires while the app is active, and clicking a menu bar icon does not activate an accessory app — so key navigation silently died on click-open.

`TriageDeckView` solves this with a zero-size first-responder `NSView` (`KeyCaptureView`) that overrides `keyDown`.
It receives keys whenever the popover window is key, independent of app-active state.
It also handles Esc-to-close, since the first responder otherwise swallows the popover's built-in Esc dismissal.

## Where to read next

- [`../CLAUDE.md`](../CLAUDE.md) — the agent hot path: rules, commands, and the file map.
- [Release pipeline](./release.md) — how builds ship.
- [Telemetry](./telemetry.md) — the observability contract.
