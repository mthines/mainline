# Mainline — Agent Guidance

## Build & Verify

```bash
# Build (from repo root — xcodeproj is at root level)
xcodebuild -scheme Mainline -configuration Debug -destination "platform=macOS" build

# Quick build check after editing
xcodebuild -scheme Mainline -configuration Debug -destination "platform=macOS" build 2>&1 | tail -5
```

## Release

```bash
# Local release (interactive — bumps version, builds, zips, updates tap, pushes)
pnpm release
# or: bash scripts/release.sh

# One-time tap setup (creates homebrew-mainline repo locally + prints next steps)
pnpm setup-tap
# or: bash scripts/setup-tap.sh
```

CI releases run automatically: push to `main` → stable; non-draft PR → beta.
See `docs/release.md` for secrets, trigger model, and signing setup.

## Architecture

```
Mainline.xcodeproj/                 ← Xcode project (at repo root)
Mainline/Mainline/                     ← Source root
├── MainlineApp.swift               ← @main, MenuBarExtra scene, AppDelegate
├── Models/
│   ├── PRSnapshot.swift         ← Canonical diff unit (one per PR); mergeable+headRefName+lines fields
│   ├── PRTransition.swift       ← Output of diff engine (4 cases)
│   ├── AttentionPolicy.swift    ← PREvent → AttentionLevel map (notify/quiet); .defaults
│   └── MainlineSettings.swift      ← UserDefaults-backed settings + global-shortcut defaults
├── Services/
│   ├── KeychainHelper.swift     ← PAT storage (async, never blocks @MainActor)
│   ├── GitHubClient.swift       ← GraphQL search + mutations + REST diff/files
│   ├── PRStateStore.swift       ← @MainActor [nodeId: PRSnapshot] dict
│   ├── PRDiffEngine.swift       ← Pure diff(previous:next:myLogin:)
│   ├── PRPoller.swift           ← Task-based poll loop + pollOnce()
│   ├── NotificationService.swift← UNNotificationRequest per transition
│   ├── PRManager.swift          ← @MainActor orchestrator + write actions
│   ├── SensitivePathMatcher.swift ← Pure path/branch-name heuristic classifier
│   ├── TriageClassifier.swift   ← Pure needsHuman predicate engine
│   ├── ScopeStore.swift         ← @MainActor derives org/repo scopes from PR list; drives badge
│   ├── SnoozeStore.swift        ← @MainActor snooze wrapper over MainlineSettings
│   ├── GlobalHotKey.swift       ← Carbon global hotkey + MenuBarPopoverOpener
│   └── TelemetryService.swift   ← Opt-in OTel singleton (no-op when disabled)
└── Views/
    ├── MenuBarView.swift         ← MenuBarExtra panel; single actionability-grouped TriageDeckView
    ├── SettingsView.swift        ← PAT entry, gh import, toggles, write-actions, shortcut recorder, panel min/max height
    ├── MenuBarIconView.swift     ← Dynamic badge: MenuBarBadge enum → SF Symbol + tint
    ├── TriageDeckView.swift      ← Keyboard triage (J/K/Space/↵/A/M/R/S/E/X/V/⌘Z) + TriageAction enum + per-row context menu + first-responder KeyCaptureView
    ├── PRPeekView.swift          ← Space peek: instant glance card + async files list
    ├── UndoToastView.swift       ← Batched undo toast stack
    ├── TelemetryOptInBanner.swift← Dismissable Privacy-pane opt-in banner (consent-versioned)
    └── TelemetryDetailsSheet.swift ← Full telemetry disclosure sheet
```

## Key Patterns

### State ownership
All PR state lives in `PRStateStore`. `PRPoller` never writes snapshots directly — it calls `PRStateStore.update(new:myLogin:)` which runs `PRDiffEngine` and returns transitions.

### Keychain
`KeychainHelper` is async-only. Never call `loadToken()` synchronously on `@MainActor` — it calls `Task.detached` internally.

### Notification IDs
`NotificationService` uses deterministic IDs (`mainline.new_pr.<nodeId>`) so rapid polls replace rather than stack banners.

### pbxproj wiring
Every new Swift source file **must** appear in all three places:
1. `PBXFileReference` section
2. `PBXBuildFile` section  
3. `PBXSourcesBuildPhase` files list

Missing any one silently breaks the build with no obvious error.

### Thread model
`PRManager`, `PRPoller`, `PRStateStore`, `SnoozeStore` are all `@MainActor`. Background work (Keychain, URLSession, JSON I/O) uses `Task.detached` and bridges back via the async boundary.

### Pure-shell pattern
Pure logic (no I/O): `PRDiffEngine`, `TriageClassifier`, `SensitivePathMatcher` — testable without mocks.
Impure shell (I/O or state): `PRStateStore`, `SnoozeStore` — own persistence.

### Write actions
Write actions (Approve, Merge, Request Changes) are gated by `settings.writeActionsEnabled` (default OFF). Always show an `NSAlert` confirmation before calling the GitHub API.

### Keyboard events in MenuBarExtra
`.onKeyPress` requires macOS 14+ (deployment target is 13). A local `NSEvent` monitor only fires while the app is *active*, and clicking the menu bar icon does NOT activate an accessory app — so key nav silently died on click-open. Instead `TriageDeckView` embeds a zero-size first-responder `NSView` (`KeyCaptureView`) that overrides `keyDown`: it receives keys whenever the popover window is key, independent of app-active state. It also handles Esc-to-close (the first responder otherwise swallows the popover's built-in Esc dismissal).

### Global shortcut
System-wide hotkey to open the popover, via Carbon `RegisterEventHotKey` in `GlobalHotKey`. Stored as `globalShortcutKeyCode` + `globalShortcutModifiers` (Cocoa `NSEvent.ModifierFlags` raw value; converted to a Carbon mask by `GlobalHotKey.carbonModifiers(from:)`). `AppDelegate.setUpGlobalHotKey()` subscribes to the three `MainlineSettings` published props so the recorder, toggle, and reset button all live re-register. Default: **⇧⌃ + ISO section key** (`kVK_ISO_Section` = 0x0A; the "$" key on a Danish layout) — see `defaultShortcutKeyCode`/`defaultShortcutModifiers`. `keyGlyph(for:)` renders the key label, falling back to `UCKeyTranslate` against the active keyboard layout for non-ANSI physical keys.

## Keychain Details

- Service: `"com.mainline.github-pr-notifier"`
- Account: `"github-pat"`
- Class: `kSecClassGenericPassword`
- No App Sandbox (non-sandboxed enables outbound network + Keychain + `gh` subprocess)

## UserDefaults Keys

Full list of keys is `MainlineSettings.Keys`; the notable ones:

| Key | Type | Default |
|-----|------|---------|
| `pollIntervalSeconds` | Int | 60 |
| `searchQueryAuthor` | String | `is:open is:pr author:@me` |
| `searchQueryReviewer` | String | `is:open is:pr review-requested:@me` |
| `notifyNewPR` / `Ready` / `CI` / `Comment` | Bool | true |
| `notifyOnlyHumanComments` | Bool | true |
| `githubUsername` | String | `""` |
| `etag_<url>` | String | — |
| `writeActionsEnabled` | Bool | false |
| `mergeMethodPreference` | String | `auto` |
| `collapsedSectionsRaw` | [String] | [] |
| `snoozeMapData` | Data (JSON) | {} |
| `attentionPolicy` | Data (JSON) | `PREvent.defaults` |
| `panelHeight` | Int | 560 |
| `panelMinHeight` | Int | 240 |
| `menuBarMetric` | String | `needsAHuman` |
| `globalShortcutEnabled` | Bool | true |
| `globalShortcutKeyCode` | Int | `0x0A` (ISO section key) |
| `globalShortcutModifiers` | UInt | ⇧⌃ |
| `telemetryEnabled` | Bool | false |

## Bundle ID

`com.mainline.github-pr-notifier` — matches Keychain service and `PRODUCT_BUNDLE_IDENTIFIER`.

## macOS Version

Deployment target: **macOS 13.0**. Use only APIs available on 13+. `MenuBarExtra` requires 13+.

## Telemetry

Mainline ships opt-in anonymous observability via OpenTelemetry (opentelemetry-swift 1.17.1 → OTLP/HTTP → Dash0).

**Default:** OFF. User opts in via Settings → Privacy banner or toggle.

**Full architecture, signal design, privacy contract, and instrumentation guide:** `docs/telemetry.md`

**Quick reference:**
- Entry point: `TelemetryService.shared` — all methods no-op when `MainlineSettings.telemetryEnabled` is false.
- `configure()` called from `MainlineSettings.telemetryEnabled.didSet` (on enable) and on app launch.
- `shutdown()` called in `AppDelegate.applicationWillTerminate`.
- Privacy rule: NEVER pass PR titles, repo names, branch names, user logins, or tokens to any `TelemetryService` method.
- To add instrumentation: add a bounded-parameter method to `TelemetryService`, add the counter/histogram instrument in `setupOTel()`, call from the instrumented site. See `docs/telemetry.md` for the full guide.
