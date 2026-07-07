# Mainline — Agent Guidance

## Build & Verify

```bash
# Build (from repo root — xcodeproj is at root level)
xcodebuild -scheme Mainline -configuration Debug -destination "platform=macOS" build

# Quick build check after editing
xcodebuild -scheme Mainline -configuration Debug -destination "platform=macOS" build 2>&1 | tail -5
```

## Architecture

```
Mainline.xcodeproj/                 ← Xcode project (at repo root)
Mainline/Mainline/                     ← Source root
├── MainlineApp.swift               ← @main, MenuBarExtra scene, AppDelegate
├── Models/
│   ├── PRSnapshot.swift         ← Canonical diff unit (one per PR); mergeable+headRefName+lines fields
│   ├── PRTransition.swift       ← Output of diff engine (4 cases)
│   ├── MainlineSettings.swift      ← UserDefaults-backed settings
│   └── TrustLedger.swift        ← VerdictRecord, TrustTier, TrustCalculator (pure)
├── Services/
│   ├── KeychainHelper.swift     ← PAT storage (async, never blocks @MainActor)
│   ├── GitHubClient.swift       ← GraphQL search + mutations + REST diff/files
│   ├── PRStateStore.swift       ← @MainActor [nodeId: PRSnapshot] dict
│   ├── PRDiffEngine.swift       ← Pure diff(previous:next:myLogin:)
│   ├── PRPoller.swift           ← Task-based poll loop + pollOnce()
│   ├── NotificationService.swift← UNNotificationRequest per transition
│   ├── PRManager.swift          ← @MainActor orchestrator + write actions + autopilot
│   ├── SensitivePathMatcher.swift ← Pure path/branch-name heuristic classifier
│   ├── TriageClassifier.swift   ← Pure needsHuman predicate engine
│   ├── TrustLedgerStore.swift   ← @MainActor JSON persistence (Application Support)
│   └── SnoozeStore.swift        ← @MainActor snooze wrapper over MainlineSettings
└── Views/
    ├── MenuBarView.swift         ← MenuBarExtra panel; single actionability-grouped TriageDeckView
    ├── SettingsView.swift        ← PAT entry, gh import, toggles, write-actions/autopilot
    ├── MenuBarIconView.swift     ← Dynamic badge: MenuBarBadge enum → SF Symbol + tint
    ├── TriageDeckView.swift      ← Keyboard triage: J/K/Space/A/M/R/S/E/X/⌘K/⌘Z
    ├── DiffPreviewView.swift     ← Quick Look diff overlay (REST .diff fetch)
    ├── CommandPaletteView.swift  ← ⌘K Raycast-style palette
    ├── UndoToastView.swift       ← Batched undo toast stack
    └── TrustBadgeView.swift      ← Compact P/T/A tier dot for PR rows
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
`PRManager`, `PRPoller`, `PRStateStore`, `TrustLedgerStore`, `SnoozeStore` are all `@MainActor`. Background work (Keychain, URLSession, JSON I/O) uses `Task.detached` and bridges back via the async boundary.

### Pure-shell pattern
Pure logic (no I/O): `PRDiffEngine`, `TriageClassifier`, `TrustCalculator`, `SensitivePathMatcher` — testable without mocks.
Impure shell (I/O or state): `PRStateStore`, `TrustLedgerStore`, `SnoozeStore` — own persistence.

### Write actions
Write actions (Approve, Merge, Request Changes) are gated by `settings.writeActionsEnabled` (default OFF). Always show an `NSAlert` confirmation before calling the GitHub API. Autopilot auto-approve requires both `writeActionsEnabled` AND `autopilotEnabled`.

### Keyboard events in MenuBarExtra
`.onKeyPress` requires macOS 14+. Use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` for macOS 13 compatibility. Install in `.onAppear`, remove in `.onDisappear`. Force first-responder in `.onAppear` via `NSApp.keyWindow?.makeFirstResponder(NSApp.keyWindow?.contentView)`.

## Keychain Details

- Service: `"com.mainline.github-pr-notifier"`
- Account: `"github-pat"`
- Class: `kSecClassGenericPassword`
- No App Sandbox (non-sandboxed enables outbound network + Keychain + `gh` subprocess)

## UserDefaults Keys

| Key | Type | Default |
|-----|------|---------|
| `pollIntervalSeconds` | Int | 60 |
| `searchQueryAuthor` | String | `is:open is:pr author:@me` |
| `searchQueryReviewer` | String | `is:open is:pr review-requested:@me` |
| `notifyNewPR` / `Ready` / `CI` / `Comment` | Bool | true |
| `githubUsername` | String | `""` |
| `etag_<url>` | String | — |
| `writeActionsEnabled` | Bool | false |
| `autopilotEnabled` | Bool | false |
| `collapsedSectionsRaw` | [String] | [] |
| `snoozeMapData` | Data (JSON) | {} |

## Trust Ledger

JSON file at `~/Library/Application Support/com.mainline.github-pr-notifier/trust-ledger.json`. Keyed by author login → `[VerdictRecord]`. `TrustLedgerStore.load()` returns empty dict silently on missing/corrupt file.

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
