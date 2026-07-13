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
│   └── MainlineSettings.swift      ← UserDefaults-backed settings + global-shortcut defaults; `InAppShortcut` enum + `ShortcutBinding` value type + `InAppShortcutBindings` custom-Codable struct for configurable deck/peek shortcuts (supports modifier combos ⌘⇧⌃⌥ per binding)
├── Services/
│   ├── KeychainHelper.swift     ← PAT storage (async, never blocks @MainActor); account-parameterized
│   ├── GitHubClient.swift       ← GraphQL search + mutations + REST diff/files; author now decoded with __typename for bot detection; labels(first:10) added
│   ├── PRStateStore.swift       ← @MainActor [nodeId: PRSnapshot] dict
│   ├── PRDiffEngine.swift       ← Pure diff(previous:next:myLogin:)
│   ├── PRPoller.swift           ← Task-based poll loop + pollOnce()
│   ├── NotificationService.swift← UNNotificationRequest per transition
│   ├── PRManager.swift          ← @MainActor orchestrator + write actions; inbox-derived populations (inboxActivePRs, inboxMutedPRs, inboxMuteConfig); currentViewPRs routes to inboxActivePRs on .inbox tab
│   ├── SensitivePathMatcher.swift ← Pure path/branch-name heuristic classifier
│   ├── TriageClassifier.swift   ← Pure needsHuman predicate engine
│   ├── InboxMuteEngine.swift    ← Pure glob matcher + four mute-rule predicates (pattern/botAuthor/label/outsideFocus); InboxMuteConfig value struct; runSelfChecks() #if DEBUG
│   ├── ScopeStore.swift         ← @MainActor derives org/repo scopes from PR list; drives badge
│   ├── SnoozeStore.swift        ← @MainActor snooze wrapper over MainlineSettings
│   ├── GlobalHotKey.swift       ← Carbon global hotkey + MenuBarPopoverOpener
│   ├── TelemetryService.swift   ← Opt-in OTel singleton (no-op when disabled)
│   ├── DemoMode.swift           ← Feature flag (env `MAINLINE_DEMO` / defaults `demoModeEnabled`) + canned demo dataset factory
│   └── MockGitHubClient.swift   ← `GitHubAPI` protocol (real + mock share it) + in-memory fake for demo/recording mode
└── Views/
    ├── MenuBarView.swift         ← MenuBarExtra panel; single actionability-grouped TriageDeckView; passes mutedPRs + inboxMode to TriageDeckView on .inbox tab
    ├── SettingsView.swift        ← PAT entry, gh import, toggles, write-actions, shortcut recorder, panel min/max height; includes `.inbox` SettingsCategory routing to InboxSettingsView and `.keyboard` routing to KeyboardShortcutsView
    ├── InboxSettingsView.swift   ← Inbox noise-filter settings: mute patterns, muteBotAuthors toggle, reviewFocusAuthors/Teams, muteLabels
    ├── KeyboardShortcutsView.swift ← Configurable deck/peek shortcuts UI: per-action `InAppShortcutRecorder`, clash detection, Reset All button
    ├── MenuBarIconView.swift     ← Dynamic badge: MenuBarBadge enum → SF Symbol + tint
    ├── TriageDeckView.swift      ← Keyboard triage (J/K/Space/↵/E/M/R/S/N/X/V/D/Q/⌘Z) + TriageAction enum + per-row context menu + first-responder KeyCaptureView; deck keys are user-configurable via settings.shortcutBindings; Inbox mode: role sections (yourPRs / needsYourReview) + collapsed Muted group; Q toggles per-PR manual mute (settings.inboxMuteOverrides)
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

All 13 in-popover deck/peek action keys are **user-configurable** via Settings → Keyboard (`KeyboardShortcutsView`). Each binding stores a base key AND a modifier set (⌘⇧⌃⌥) as a `ShortcutBinding { key: String, modifiers: UInt }` value type — `modifiers` mirrors the global-hotkey's `NSEvent.ModifierFlags.rawValue` storage. `handleKeyDown` reads bindings from `settings.shortcutBindings` at runtime via `shortcutMatches(_:event:)`, which compares BOTH the base key (from `charactersIgnoringModifiers`) AND the masked modifier flags — never hardcoded literals. Default bindings: E=preview, N=markSeen, Q=toggleMute (Inbox mute / move-up), J/K/Space/M/R/S/X/V/D bare; **undo=⌘Z** (⌘ stored in the binding, not a hardcoded branch). **Left-hand default policy:** new in-app shortcut *defaults* should favour left-hand keys (Q W E R T A S D F G Z X C V B) so the deck is usable one-handed while the pointing hand stays on the trackpad/mouse. (Vim-convention J/K nav and mnemonic M/N are deliberate exceptions; anything reached frequently should default left-hand. Users can always rebind.) The `InAppShortcutRecorder` captures modifiers alongside the key (mirroring `ShortcutRecorder` but without the non-empty-modifier guard, since bare keys are valid in-app). Persisted as JSON in UserDefaults (`shortcutBindings`); the custom `Codable` decodes BOTH the new `ShortcutBinding` object shape and the v1.25.0 legacy bare-string shape. Migration rule: a v1.25.0 `undo` bare string gets `.command` applied so ⌘Z is preserved on upgrade; all other bare-string fields decode with empty modifiers.

### Global shortcut
System-wide hotkey to open the popover, via Carbon `RegisterEventHotKey` in `GlobalHotKey`. Stored as `globalShortcutKeyCode` + `globalShortcutModifiers` (Cocoa `NSEvent.ModifierFlags` raw value; converted to a Carbon mask by `GlobalHotKey.carbonModifiers(from:)`). `AppDelegate.setUpGlobalHotKey()` subscribes to the three `MainlineSettings` published props so the recorder, toggle, and reset button all live re-register. Default: **⇧⌃ + ISO section key** (`kVK_ISO_Section` = 0x0A; the "$" key on a Danish layout) — see `defaultShortcutKeyCode`/`defaultShortcutModifiers`. `keyGlyph(for:)` renders the key label, falling back to `UCKeyTranslate` against the active keyboard layout for non-ANSI physical keys.

### Inbox / review focus

The **Inbox tab** (`ReviewTab.inbox`) is a client-side derived union of the forMe + created queries. `PRManager` deduplicates by `nodeId`, then passes each snapshot through `InboxMuteEngine.muteVerdict(...)` — nil = active (shown in role sections), non-nil = muted (collapsed Muted group at the bottom). Four mute rules apply in priority order: (1) glob patterns on title+branch via `InboxMuteConfig.mutePatterns`, (2) bot-author detection (`muteBotAuthors`), (3) label matching (`muteLabels`), (4) focus allow-list (`reviewFocusAuthors` + `reviewFocusTeams`). Rule 4 is skipped for `.yourPRs` role — your own PRs are never muted by focus. GraphQL now fetches `author { __typename login }` (for bot detection via `__typename == "Bot"`) and `labels(first: 10) { nodes { name } }`. New `PRSnapshot` fields (`labels`, `authorIsBot`) decode with `decodeIfPresent` so old persisted snapshots are backward-compatible; neither field triggers a diff-engine transition (excluded by omission from `PRDiffEngine`).

### Vercel preview detection
Each PR can carry a `vercelPreviewUrl` extracted from its `vercel[bot]` issue comment (REST `GitHubClient.fetchVercelPreviewURL`, pure `extractPreviewURL(from:domains:)`). The row shows a `PreviewBadge` when present, and `E` (deck or peek, default binding — user-configurable) opens it via `TriageDeckView.openPreview` (silent no-op when absent). Enrichment is **lazy + cached** in `PRPoller.enrichVercelPreviews`: the URL is keyed on `PRSnapshot.vercelPreviewCheckedAt` (the `updatedAt` it was checked at), carried forward while `updatedAt` is unchanged, and re-fetched only when a new commit bumps `updatedAt` — so a steady poll makes ~zero extra REST calls. Applied via `PRStateStore.applyVercelPreviews` (patches + persists, never re-diffs — a preview is not a notifiable transition). Match domains (priority order) and the on/off toggle are `MainlineSettings.vercelPreviewDomains` / `vercelPreviewEnabled`.

### PR open target (GitHub / Linear)
The primary "open" action (click / ↵ / `openInBrowser` verb) routes through `PRManager.openPR(_:)` (sync). GitHub by default. Linear is used only when the PR's repo passes `PROpenTarget.repoUsesLinear(repoFullName:filter:)` against `settings.linearRepoFilter` (a `[String]` allowlist of orgs `owner` or exact repos `owner/repo`; **empty = all repos**) — so work repos can open in Linear while personal repos stay on GitHub. When Linear applies it opens the PR's **review view** derived from the PR URL alone (no API key, no workspace slug): `PROpenTarget.linearDesktopURL(fromPRURL:)` builds `linear://linear.app/review/<owner>/<repo>/pull/<n>` — the `linear://` custom scheme is the only form that hands off to the Linear **desktop app** (the `/review/*` path is NOT in Linear's universal-link AASA, so `https` forms only ever open the browser). If the desktop app isn't installed (`NSWorkspace.open` returns false) it falls back to `PROpenTarget.linearWebURL(fromPRURL:)` = `https://linear.review/<path>` (Linear redirects it to the review page), then to the GitHub PR page. `openPR` records the `open_in_browser` interaction once, centrally. The peek card's Safari button (`PRPeekView`) always opens GitHub via `htmlUrl`.

### Demo / screen-recording mode
A **temporary, opt-in** switch (`DemoMode`) that swaps the live network layer for a canned in-memory dataset so recordings show every visual state without a real account. Enabled by env var `MAINLINE_DEMO=1` **or** UserDefaults `demoModeEnabled` (`defaults write com.mainline.github-pr-notifier demoModeEnabled -bool YES`). Mechanism: `GitHubClient` and `MockGitHubClient` both conform to the **`GitHubAPI`** protocol; `PRManager.init` picks the mock when `DemoMode.isEnabled` and shares the SAME instance with `PRPoller` (so write actions mutate state the next poll reads). `PRManager.start()` / `performAction` / `PRPeekView.loadFiles` bypass the Keychain token in demo mode; `PRStateStore` persists to a separate `pr-snapshots-demo.json` (isolated + quiet first run). The mock (`MockGitHubClient`, an `actor`) serves `DemoMode.dataset(myLogin:)` — a spread covering Ready-to-merge / Needs-attention (failing CI, changes requested, unresolved threads) / Waiting / Draft / Muted bot PRs / Vercel previews / large PR / Done (merged + closed), across `dash0hq` + `mthines` repos and both tabs — and mutates it on Approve (→ approved), Request changes (→ changes requested), and Merge (→ moves to Done). Everything else (polling, diff engine, notifications, keyboard triage, collapse/hide/snooze/mute) runs unchanged.

## Keychain Details

- Service: `"com.mainline.github-pr-notifier"`
- Account: `"github-pat"`
- Class: `kSecClassGenericPassword`
- No App Sandbox (non-sandboxed enables outbound network + Keychain + `gh` subprocess)

## UserDefaults Keys

Full list of keys is `MainlineSettings.Keys`; the notable ones:

| Key | Type | Default |
|-----|------|---------|
| `pollIntervalSeconds` | Int | 30 |
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
| `attentionPolicy` | Data (JSON) | `PREvent.defaults` (reviewRequested = quiet) |
| `panelHeight` | Int | 1600 |
| `panelMinHeight` | Int | 600 |
| `menuBarMetric` | String | `totalOpen` |
| `globalShortcutEnabled` | Bool | true |
| `globalShortcutKeyCode` | Int | `0x0A` (ISO section key) |
| `globalShortcutModifiers` | UInt | ⇧⌃ |
| `vercelPreviewEnabled` | Bool | true |
| `vercelPreviewDomains` | [String] | `["dash0-preview.com","vercel.app"]` |
| `telemetryEnabled` | Bool | false |
| `shortcutBindings` | Data (JSON) | `InAppShortcutBindings.defaults` — 12 `ShortcutBinding { key, modifiers }` entries; all bare except undo=⌘Z (`modifiers = NSEvent.ModifierFlags.command.rawValue`). Decoded with custom `Codable` that handles both the new object shape and the v1.25.0 legacy bare-string shape; undo bare-string → `.command` migration preserves ⌘Z for existing users. |
| `mutePatterns` | [String] | `["chore(deps)*", "build(deps)*"]` |
| `muteBotAuthors` | Bool | true |
| `reviewFocusAuthors` | [String] | `[]` |
| `reviewFocusTeams` | [String] | `[]` |
| `muteLabels` | [String] | `[]` |

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
