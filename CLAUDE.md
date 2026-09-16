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

CI releases: push to `main` → stable (automatic); comment `/beta` on a PR → beta (on-demand).
PRs otherwise run a Debug smoke build only. Betas are on-demand because the macOS build+sign+
notarize can only run on metered macOS runners. See `docs/release.md` for secrets, trigger
model, and signing setup.

## Architecture

```
Mainline.xcodeproj/                 ← Xcode project (at repo root)
Mainline/Mainline/                     ← Source root
├── MainlineApp.swift               ← @main, MenuBarExtra scene, AppDelegate
├── Models/
│   ├── PRSnapshot.swift         ← Canonical diff unit (one per PR); mergeable+headRefName+lines fields; `viewerHasApproved` (viewer's own latest review == APPROVED, from GraphQL `latestReviews`); role-aware `actionGroup(splitDrafts:myLogin:reviewReady:)` + `needsMyTime(...)` + `ReviewReadyConfig`; `PRClassificationChecks.run()` #if DEBUG
│   ├── PRTransition.swift       ← Output of diff engine (4 cases)
│   ├── AttentionPolicy.swift    ← PREvent → AttentionLevel map (notify/quiet); `.defaults` (reviewRequested = notify); `isDeliverable`/`deliverable` SSOT for which events can actually fire; pure `migratedPolicy(from:)` + `policyMigrationVersion` for persisted-policy upgrades; `AttentionPolicyChecks.run()` #if DEBUG
│   └── MainlineSettings.swift      ← UserDefaults-backed settings + global-shortcut defaults; `InAppShortcut` enum + `ShortcutBinding` value type + `InAppShortcutBindings` custom-Codable struct for configurable deck/peek shortcuts (supports modifier combos ⌘⇧⌃⌥ per binding); `launchAtLogin` (SMAppService-backed launch-at-login toggle)
├── Services/
│   ├── KeychainHelper.swift     ← PAT storage (async, never blocks @MainActor); account-parameterized
│   ├── GitHubClient.swift       ← GraphQL search + mutations + REST diff/files; author now decoded with __typename for bot detection; labels(first:10) added
│   ├── PRStateStore.swift       ← @MainActor [nodeId: PRSnapshot] dict
│   ├── PRDiffEngine.swift       ← Pure diff(previous:next:myLogin:)
│   ├── PRPoller.swift           ← Task-based poll loop + pollOnce(); pure `carryingForward(fetched:previous:incompleteTabs:)` → `CarryForwardResult` keeps a 304 / 5xx / degraded-page tab from shrinking the diff baseline and counts what it rescued (`mainline.poll.carried_forward`); `CarryForwardReason` enum; `PollCarryForwardChecks.run()` #if DEBUG
│   ├── NotificationService.swift← UNNotificationRequest per transition; `async requestAuthorization()` (no longer discards `granted`); `authorizationState()` + pure `classify(...)` → `NotificationAuthorizationState`; `openSystemNotificationSettings()`; case-insensitive `resolveTransition` via `PRSnapshot.loginsMatch`; `NotificationRoutingChecks.run()` #if DEBUG
│   ├── PRManager.swift          ← @MainActor orchestrator + write actions; inbox-derived populations (inboxActivePRs, inboxMutedPRs, inboxMuteConfig); currentViewPRs routes to inboxActivePRs on .inbox tab; self-healing `refreshUsername` (nonisolated fetch + `UsernameFetchError` + published `usernameError`); published `notificationAuthorization` via `refreshNotificationAuthorization()`
│   ├── SensitivePathMatcher.swift ← Pure path/branch-name heuristic classifier
│   ├── TriageClassifier.swift   ← Pure needsHuman predicate engine
│   ├── PRSearchFilter.swift     ← Pure search matcher (number / PR-URL / free-text); `matches(_:query:)` + `runSelfChecks()` #if DEBUG
│   ├── InboxMuteEngine.swift    ← Pure glob matcher + four mute-rule predicates (pattern/botAuthor/label/outsideFocus); InboxMuteConfig + per-org OrgFocusConfig value structs; muteVerdict takes the PR's `org`; runSelfChecks() #if DEBUG
│   ├── ScopeStore.swift         ← @MainActor derives org/repo scopes from PR list; drives badge
│   ├── SnoozeStore.swift        ← @MainActor snooze wrapper over MainlineSettings
│   ├── GlobalHotKey.swift       ← Carbon global hotkey + MenuBarPopoverOpener
│   └── TelemetryService.swift   ← Opt-in OTel singleton (no-op when disabled)
│   └── LaunchAtLoginService.swift ← SMAppService-backed launch-at-login registration (pure enum, no I/O on the main thread)
└── Views/
    ├── MenuBarView.swift         ← MenuBarExtra panel; single actionability-grouped TriageDeckView; passes mutedPRs + inboxMode to TriageDeckView on .inbox tab
    ├── SettingsView.swift        ← PAT entry, gh import, toggles, write-actions, shortcut recorder, panel min/max height; includes `.inbox` SettingsCategory routing to InboxSettingsView and `.keyboard` routing to KeyboardShortcutsView; GitHub pane shows the resolved login + `usernameError`; Notifications pane shows the macOS-permission warning (+ Open System Settings) and drives the Attention Policy list from `PREvent.deliverable`
    ├── InboxSettingsView.swift   ← Inbox noise-filter settings: Review Readiness (four reviewer "not ready → Waiting" toggles: conflict / failing CI / unresolved threads / approved-by-me, all default ON), mute patterns, muteBotAuthors toggle, per-org Review Focus (org sub-blocks nested INSIDE the one Review Focus card via `orgFocusBlock`, each with a Remove button; authors+teams keyed by lowercased org, derived from `manager.knownOrgs` + saved config + an add-org field), muteLabels
    ├── KeyboardShortcutsView.swift ← Configurable deck/peek shortcuts UI: per-action `InAppShortcutRecorder`, clash detection, Reset All button
    ├── MenuBarIconView.swift     ← Dynamic badge: MenuBarBadge enum → SF Symbol + tint
    ├── TriageDeckView.swift      ← Keyboard triage (J/K/Space/↵/E/M/T/R/S/N/X/V/D/Q/C/P/F/⌘Z) + TriageAction enum + per-row context menu + first-responder KeyCaptureView; deck keys are user-configurable via settings.shortcutBindings; Inbox mode: role sections (yourPRs / needsYourReview) + collapsed Muted group; Q toggles per-PR manual mute (settings.inboxMuteOverrides); T marks draft PR ready for review (draft-only, write-gated, plain toast); P pins/unpins the focused PR (floats it to the top of its group, `settings.pinnedNodeIds`); F opens the flat search-results view (`searchMode`)
    ├── PRPeekView.swift          ← Space peek: instant glance card + async files list
    ├── UndoToastView.swift       ← Batched undo toast stack
    ├── TelemetryOptInBanner.swift← Dismissable Privacy-pane opt-in banner (consent-versioned)
    └── TelemetryDetailsSheet.swift ← Full telemetry disclosure sheet
```

## Key Patterns

### State ownership
All PR state lives in `PRStateStore`. `PRPoller` never writes snapshots directly — it calls `PRStateStore.update(new:myLogin:)` which runs `PRDiffEngine` and returns transitions.

### The diff baseline is the fetched array — an incomplete fetch re-notifies

`PRStateStore.update` rebuilds its dict from **exactly** the array it is handed, and
`PRDiffEngine` emits `.newPR` for any nodeId absent from that baseline. So a PR
dropped from one poll's array does not merely disappear for a cycle — it returns as a
brand-new PR on the next complete poll, re-firing its notification and re-lighting its
unread dot. Anything that can hand `update` a PARTIAL result set must therefore carry
the missing PRs forward:

- **No data** — a 304, or a 5xx that survived `GitHubClient.searchPRs`'s retry.
- **Partial data** — the post-5xx retry succeeded at `searchPageSizeDegraded` (50)
  instead of `searchPageSize` (100), so it returned a subset. `searchPRs` reports this
  as its `degraded` flag; the flag is load-bearing, not diagnostic. Treating a degraded
  page as the whole tab is what made ~18% of reviewer polls silently halve the baseline
  and re-notify ~49 team-review PRs on the following poll (thousands of spurious
  `reviewRequestedTeam` events a day).

Both land in `PRPoller.poll`'s `incompleteTabs` map (`[ReviewTab: CarryForwardReason]`
— the reason is kept, not just the fact) and go through the pure
`PRPoller.carryingForward(fetched:previous:incompleteTabs:)`, which re-adds each
missing snapshot **verbatim** — an unchanged snapshot diffs to no transition, so the
list is preserved without notifying. A *complete* poll deliberately does NOT carry
forward: that is how a PR that genuinely left the search set gets dropped.

Its `CarryForwardResult.carriedByReason` feeds `mainline.poll.carried_forward`, which
is **the guard's own regression signal**: every PR counted there is one that would
otherwise have re-fired as a `.newPR` notification. A PR in two incomplete tabs counts
ONCE, under `degraded_page` over `no_data`, so the total stays a true PR count.
Watch for the counter falling to zero while `poll.degraded="true"` keeps arriving —
that means degraded pages still happen and nothing is protecting the baseline.

### Keychain
`KeychainHelper` is async-only. Never call `loadToken()` synchronously on `@MainActor` — it calls `Task.detached` internally.

`loadToken()` reads the Keychain **once per launch** and serves every later caller from an in-memory cache (`TokenCache` actor). This matters because each `SecItemCopyMatching` can raise a macOS Keychain-access prompt when the running binary isn't on the item's ACL — the state right after an update re-signs the app — so an uncached read would prompt separately at each of the many call sites (poll loop, pin fetches, search, peek, write actions), and a recurring caller (pin-fetch refresh runs every poll) would re-prompt every ~30s. The cache collapses that to a single prompt per launch (none after "Always Allow" on a stably-signed release). Concurrent first-loads are coalesced onto one Keychain read (`inFlight`). `saveToken` seeds the cache with the new value; `deleteToken` invalidates it — so callers never re-read a token the app just wrote or cleared.

### Notification IDs
`NotificationService` uses deterministic IDs (`mainline.new_pr.<nodeId>`) so rapid polls replace rather than stack banners.

### Notification delivery contract

Three independent gates must ALL pass for a banner to appear. When debugging "no
notifications", check them in this order — the first two used to fail silently:

1. **macOS authorization.** `NotificationService.authorizationState()` reads
   `getNotificationSettings` (via a continuation, not the `async` accessor — macOS 13
   availability) and classifies it with the pure
   `classify(authorizationStatus:alertStyle:alertSetting:)`. `.denied` and `.silent`
   (authorized but alert style "None", or alerts disabled) both suppress every banner.
   Surfaced as a warning + "Open System Settings…" button in Settings → Notifications,
   backed by `PRManager.notificationAuthorization`. `requestAuthorization()` is `async`
   and no longer discards `granted`.
2. **A `PRTransition` must exist.** `PRTransition` has only FOUR cases
   (`newPR`, `readyForReview`, `ciStatusChanged`, `newReviewOrComment`), so only the
   `PREvent`s reachable from `NotificationService.resolveTransition` can ever fire.
   `PREvent.isDeliverable` / `PREvent.deliverable` is the single source of truth for
   that set and is what Settings iterates — `changesRequested` / `prMerged` / `prClosed`
   are non-deliverable (kept as cases because persisted policy dicts may carry their
   keys, but never rendered). The `isDeliverable` switch is exhaustive on purpose: a new
   `PREvent` is a compile error until its deliverability is declared.
3. **The attention level must be `.notify`.** `MainlineSettings.level(for:)` honours a
   PERSISTED value over `PREvent.defaults`, so changing a default never reaches a user
   who has opened the Notifications pane. Any such change needs a bump to
   `PREvent.policyMigrationVersion` plus a rule in the pure
   `PREvent.migratedPolicy(from:)`, run once from the trailing block of
   `MainlineSettings.init()`. v1 REMOVES a stored `reviewRequested: quiet` (removal, not
   overwrite, so future default changes also land) while preserving a deliberate `off`.

Note `resolveTransition` routes *every* new PR you did not author to `.reviewRequested`
(or `.reviewRequestedTeam` when only a team was requested) — so `reviewRequested`'s
level governs all "New PR" banners, not just direct review requests.

### Viewer identity

`PRSnapshot.loginsMatch(_:_:)` is the single source of truth for "is this me?".
GitHub logins are case-insensitive, and snapshot fields (`author`,
`requestedReviewers`) are stored **verbatim as the API returned them** — only the
local `myLogin` in `GitHubClient.makeSnapshot`'s `viewerHasApproved` match is
lowercased — so a stored `MThines` against an API `mthines` must still match.
Empty on either side never matches. Used by `inboxRole`, `reviewRequestSource`, and both
identity checks in `NotificationService.resolveTransition` — never hand-roll `==` on a
login.

`settings.githubUsername` is load-bearing, not cosmetic: an empty or mismatched value
makes `resolveTransition` drop EVERY CI notification and files your own PRs under
"Needs your review". It self-heals in `PRManager.start()` (awaited when empty so the
first poll has an identity; background re-verify when already set) via a `nonisolated`
fetch with a 15s timeout, and a failure publishes `PRManager.usernameError` instead of
being swallowed. A failed fetch never downgrades a known-good login to empty.

### Settings persistence — the `didSet`-in-`init` trap

Most `MainlineSettings` properties persist **only** through their own `didSet`
(`@Published var x { didSet { defaults.set(x, forKey: Keys.x) } }`). Swift does not run
property observers for assignments inside the declaring type's own `init`, and
`MainlineSettings` is a root class, so there is no `super.init()` boundary to escape that
window. **Every write from `init()` must therefore call `defaults.set(...)` explicitly** —
assigning the property alone changes memory and nothing else.

This is a silent, self-concealing failure: the value is correct for the rest of that
launch (so it tests fine) and reverts from the next launch on. It is worse when paired
with a version key, which marks the work done forever after a write that never landed —
exactly how the v1 attention-policy migration shipped broken. Write the data first, then
the version key, so a crash between them re-runs rather than skips.

The trap is easy to miss because `notifMutedNodeIds` seeding in the same block looks like
a counter-example. It isn't: that property is COMPUTED, so its setter body assigns the
stored `notifMutedNodeIdsList`, and *that* assignment does fire the observer. Computed
wrappers escape by accident of API shape; stored properties do not.

Everything else in `init()` is a *load* (`x = defaults.something(forKey:)`), where the
absent observer is harmless by construction — which is why only writes need the rule.

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

There is **no XCTest target**. The testing surface is `#if DEBUG` self-check
functions on pure types, all invoked from `AppDelegate.applicationDidFinishLaunching`:
`InboxMuteEngine.runSelfChecks()`, `PRSearchFilter.runSelfChecks()`, `PRClassificationChecks.run()`,
`AttentionPolicyChecks.run()`, `NotificationRoutingChecks.run()`. Add new pure logic's
assertions to one of these (or a sibling enum in the same file) rather than introducing a
test framework. Keeping the decision table pure — `PREvent.migratedPolicy(from:)`,
`NotificationService.classify(...)` — is what makes it assertable at all.

### Write actions
Write actions (Approve, Merge, Request Changes) are gated by `settings.writeActionsEnabled` (default OFF). Always show an `NSAlert` confirmation before calling the GitHub API.

### Keyboard events in MenuBarExtra
`.onKeyPress` requires macOS 14+ (deployment target is 13). A local `NSEvent` monitor only fires while the app is *active*, and clicking the menu bar icon does NOT activate an accessory app — so key nav silently died on click-open. Instead `TriageDeckView` embeds a zero-size first-responder `NSView` (`KeyCaptureView`) that overrides `keyDown`: it receives keys whenever the popover window is key, independent of app-active state. It also handles Esc-to-close (the first responder otherwise swallows the popover's built-in Esc dismissal).

All 17 in-popover deck/peek action keys are **user-configurable** via Settings → Keyboard (`KeyboardShortcutsView`). Each binding stores a base key AND a modifier set (⌘⇧⌃⌥) as a `ShortcutBinding { key: String, modifiers: UInt }` value type — `modifiers` mirrors the global-hotkey's `NSEvent.ModifierFlags.rawValue` storage. `handleKeyDown` reads bindings from `settings.shortcutBindings` at runtime via `shortcutMatches(_:event:)`, which compares BOTH the base key (from `charactersIgnoringModifiers`) AND the masked modifier flags — never hardcoded literals. Default bindings: E=preview, N=markSeen, Q=toggleMute (Inbox mute / move-up), T=markReady (draft→ready, write-gated, plain toast), C=copyBranch (copies `headRefName` to the clipboard + info toast; silent no-op when empty), P=togglePin (pin/unpin the focused PR), F=search (opens the flat search view), J/K/Space/M/R/S/X/V/D bare; **undo=⌘Z** (⌘ stored in the binding, not a hardcoded branch). **Left-hand default policy:** new in-app shortcut *defaults* should favour left-hand keys (Q W E R T A S D F G Z X C V B) so the deck is usable one-handed while the pointing hand stays on the trackpad/mouse. (Vim-convention J/K nav and the mnemonic M/N, P=pin, F=find are deliberate exceptions; anything reached frequently should default left-hand. Users can always rebind.) The `InAppShortcutRecorder` captures modifiers alongside the key (mirroring `ShortcutRecorder` but without the non-empty-modifier guard, since bare keys are valid in-app). Persisted as JSON in UserDefaults (`shortcutBindings`); the custom `Codable` decodes BOTH the new `ShortcutBinding` object shape and the v1.25.0 legacy bare-string shape. Migration rules: (1) a v1.25.0 `undo` bare string gets `.command` applied so ⌘Z is preserved on upgrade; (2) when `search` is introduced (its `.search` key is ABSENT in the stored JSON = an upgrade), `search`'s default key `f` collides with the old `markReady` default `f`, so a `markReady` still bound to bare `f` is relocated to its new default `t` to free `f` for search — a `markReady` the user deliberately rebound elsewhere is left untouched. This migration is re-derived on every launch (idempotent; it never needs to persist to be correct). All other bare-string fields decode with empty modifiers.

### Global shortcut
System-wide hotkey to open the popover, via Carbon `RegisterEventHotKey` in `GlobalHotKey`. Stored as `globalShortcutKeyCode` + `globalShortcutModifiers` (Cocoa `NSEvent.ModifierFlags` raw value; converted to a Carbon mask by `GlobalHotKey.carbonModifiers(from:)`). `AppDelegate.setUpGlobalHotKey()` subscribes to the three `MainlineSettings` published props so the recorder, toggle, and reset button all live re-register. The recorder UI (`ShortcutRecorder` + the "Global Shortcut" section) lives in the **Keyboard** settings pane (`SettingsView.keyboardSection`), directly above the in-app `KeyboardShortcutsView` — so every keyboard binding, global and in-app, sits in one place. Default: **⇧⌃ + ISO section key** (`kVK_ISO_Section` = 0x0A; the "$" key on a Danish layout) — see `defaultShortcutKeyCode`/`defaultShortcutModifiers`. `keyGlyph(for:)` renders the key label, falling back to `UCKeyTranslate` against the active keyboard layout for non-ANSI physical keys.

### Role-aware actionability

`PRSnapshot.actionGroup(splitDrafts:myLogin:reviewReady:)` is the single source of truth for section grouping, and it is **role-aware** — the top section means opposite things for a PR you authored versus one you were asked to review. Role comes from `inboxRole(myLogin:)` (`author == myLogin`).

- **Author role (your PRs)** — three buckets: `.needsAttention` (blocked on you: failing CI, changes requested, unresolved threads, **or merge conflict** — conflicts count here, unlike the role-agnostic `needsAttention`), `.readyToMerge` (approved + mergeable + green), `.waiting` (blocked on reviewers/CI).
- **Reviewer role (assigned to you)** — two buckets: `.readyForReview` (genuinely ready for your eyes) and `.waiting` (author still owns it). `readyForMyReview(_:)` gates readiness on `changesRequested` (always) plus four **user-configurable** signals in `ReviewReadyConfig` (merge conflict, failing CI, unresolved threads, `viewerHasApproved`), all default ON, edited in Settings → Inbox → Review Readiness and stored as four bools on `MainlineSettings` (`reviewReadyConfig` assembles them).

`.needsAttention` and `.readyForReview` share sortIndex 0 (they never coexist in one role's section list). The menu-bar "needs attention" badge (`PRManager.needsAttentionPRs`) now counts the role-aware `PRSnapshot.needsMyTime(myLogin:reviewReady:)` — author-role blocked-on-you PLUS reviewer-role ready-for-you — so the count means "needs my time" across both roles. `viewerHasApproved` is fetched via GraphQL `latestReviews(first:20)` matched against the authenticated login at map time (`GitHubClient.makeSnapshot` takes `myLogin`); it decodes with a `false` default and is excluded from `PRDiffEngine`.

### Inbox / review focus

The **Inbox tab** (`ReviewTab.inbox`) is a client-side derived union of the forMe + created queries. `PRManager` deduplicates by `nodeId`, then passes each snapshot through `InboxMuteEngine.muteVerdict(...)` — nil = active (shown in role sections), non-nil = muted (collapsed Muted group at the bottom). Four mute rules apply in priority order: (1) glob patterns on title+branch via `InboxMuteConfig.mutePatterns`, (2) bot-author detection (`muteBotAuthors`) with per-bot exemptions via `botAllowList`, (3) label matching (`muteLabels`), (4) **per-org** focus allow-list (`InboxMuteConfig.focusByOrg`, built from `settings.reviewFocusByOrg: [String: OrgFocusConfig]`). Rule 4 looks up ONLY the PR's own org (case-insensitive) via `InboxMuteEngine.focusConfig(for:in:)`: an org with no entry — or an empty one — has no focus rule, so all its PRs stay active, and a focus rule scoped to one org never mutes PRs in another (this replaced an earlier global-focus model where an org-local team slug like `ai` silently muted unrelated orgs' PRs). Rule 4 is also skipped for `.yourPRs` role — your own PRs are never muted by focus. The pre-per-org global keys (`reviewFocusAuthors`/`reviewFocusTeams`) are left on disk but NOT migrated into an all-orgs rule (that global apply-everywhere behavior was the bug); focus starts empty and is re-declared per org. GraphQL now fetches `author { __typename login }` (for bot detection via `__typename == "Bot"`) and `labels(first: 10) { nodes { name } }`. New `PRSnapshot` fields (`labels`, `authorIsBot`) decode with `decodeIfPresent` so old persisted snapshots are backward-compatible; neither field triggers a diff-engine transition (excluded by omission from `PRDiffEngine`).

### Pinning & in-app search

**Pinning.** A pinned PR is surfaced in a dedicated **Pinned** subsection at the TOP of the
group it belongs to — the top of the deck on the For me / Created tabs, and the top of its
ROLE group ("Your PRs" / "Needs your review") on the Inbox tab — with an orange `pin.fill` glyph
on both the section header and the row. It is a *subsection*, not a global section: each role
gets its own Pinned block, so a pinned PR you authored sits under "Your PRs › Pinned" and a
pinned PR you're reviewing under "Needs your review › Pinned". This (rather than merely floating
within another subsection) is what keeps a pin visible when the subsection it would otherwise
sit in — e.g. "Waiting" — is collapsed. The `.pinned` `ActionGroup` case is DISPLAY-ONLY: it is
never returned by `PRSnapshot.actionGroup(...)`; the deck's `sectionsWithPinned(from:)` helper
partitions each role/tab list into a leading `.pinned` section (pinned PRs, `triageOrder`-sorted)
plus the normal actionability sections built from the REST (pinned removed). Both
`actionabilitySections` and each role in `inboxSections` route through it, and `orderedPRs` /
`inboxOrderedPRs` flatten the same section order, so the keyboard index space never diverges from
the display. The Pinned subsection is collapsible, expanded by default (regular-group semantics
in `expansionBinding` / `inboxExpansionBinding`). The pinned set is `settings.pinnedNodeIds`
(persisted `[String]` nodeId list, mirroring `notifMutedNodeIds`); `PRManager` wraps it with
`isPinned` / `togglePin` / `setPinned` (undo-friendly). `sortedForDisplay(_:)` (pinned-first,
then `triageOrder`) remains the comparator for the FLAT search results and the Muted group only.
`DeckRowKey` carries `isPinned` so a pin toggle re-renders (and re-partitions) the affected rows.
Verb: `togglePin` (default `P`) + a Pin/Unpin row context item.

**Auto-unpin on merge.** With `settings.unpinOnMerge` (default ON), a pinned PR is unpinned
automatically once it MERGES, so the Pinned section stays a list of live work rather than a
graveyard of finished PRs. `PRManager.applyUnpinOnMerge(_:)` scans for pinned + `merged` snapshots
and unpins them via `settings` (direct, to avoid re-entrant fetch scheduling); it runs from the
Done-set sink (where a just-merged PR surfaces), the live-`prs` sink, and the on-demand pin fetch
(a fetched pin that has merged is unpinned instead of cached). A closed-but-unmerged PR keeps its
pin deliberately. Toggle in Settings → Appearance → Pinning.

**Pins are always visible.** A pin means "keep this in front of me," so it overrides the
noise filters — but NOT snooze (an explicit "later" wins). `PRManager.effectiveMuted` returns
`false` for a pinned PR (overriding both mute rules AND a manual mute override), so a pinned PR
pops OUT of the collapsed Muted group into its natural role/actionability section; the scope
chip (`applyingSelectedScope`, `tabFiltered`) and the Drafts toggle (`inboxUnionPRs`,
`tabFiltered`) likewise keep a pinned PR regardless. It then surfaces in the dedicated Pinned
subsection at the top of its role/tab group (see **Pinning** above). **On-demand fetch:** a pinned PR can
also fall out of the live For me / Created queries entirely (nothing to float). `PRManager`
keeps a `pinnedFetchedPRs` cache reconciled by `refreshPinnedFetches()` (run on every poll via
the `store.$snapshots` sink, and on `togglePin` / `setPinned`): it prunes entries that are
unpinned or reappeared live, then fetches each still-missing pinned nodeId via
`GitHubClient.fetchPRByNodeId(nodeId:token:)` (GraphQL `node(id:)` reusing `prNodeFields` →
`makeSnapshot`; tab membership derived from role — author → Created, else For me). Results merge
into every population through the `prsIncludingPinned` source. Guards: `pinnedFetchInFlight`
(no double-fetch), `pinnedUnfetchable` (a definitive not-found is negative-cached so a
deleted/inaccessible pin isn't refetched each poll; cleared when unpinned), and transient
errors are NOT negative-cached (next poll retries). Silent on failure — an unreachable pin just
won't surface.

**Search.** The `search` shortcut (default `F`) sets `PRManager.searchActive`, which makes
`MenuBarView` render a search `TextField` and switch the deck into `searchMode`: a single FLAT
"Results" list (no grouping, no Postponed/Done/Muted), pinned first. Focus is driven by
`searchFocusToken`; because the `TextField` is rendered conditionally on `searchActive`, both
focus handlers (`searchFocusToken` bump AND `searchActive → true`) set `searchFieldFocused`
inside `DispatchQueue.main.async` so the field exists in the tree before it is focused —
pressing `F` lands the cursor in the input. The query filters `PRManager.searchBasePRs` — every
PR in the current tab, IGNORING the scope chips and the Drafts toggle — so a pasted number or
URL always resolves. Matching is the pure `PRSearchFilter.matches(_:query:)`: a GitHub PR URL
matches repo + number (`.url` carries the number as `Int`), a bare `200` / `#200` is FUZZY —
`PRSearchFilter.Query.number` carries the digit STRING and matches as a substring of each PR's
number (`3` finds `300`/`321`/`32`), anything else is a case-insensitive substring over
title/repo/author/branch/`#number`. `PRSearchFilter.runSelfChecks()` (#if DEBUG, wired in
`MainlineApp`) asserts the parser + matcher (incl. the fuzzy-number substring cases).

**On-demand fetch.** A search target may point at a PR that isn't in the current tab's loaded
set (a repo you don't watch, a bot PR with no reviewer requested), so no local PR matches.
`MenuBarView`'s `.onChange(of: searchQuery)` calls `PRManager.resolveSearchTarget(for:)`, which
dispatches on the parsed query and appends any hit to `PRManager.searchFetchedPRs`;
`MenuBarView.searchResults` merges those into the results (deduped by nodeId). Both paths fetch
via `GitHubClient.fetchSinglePR(owner:repo:number:tab:token:)`, which reuses the shared
`prNodeFields` selection via `singlePRQueryDocument` so the result decodes through the same
`GraphQLNode` → `makeSnapshot` path; idempotent per `owner/repo#number` (`searchFetchInFlight`
guard), un-cached, silent on failure.

- **`.url`** (`resolveURLTarget`) — one lookup against the pasted repo + number.
- **`.number`** (`resolveNumberTarget`) — a bare number carries no repo, so it FANS OUT: it
  fetches that number from `candidateReposForNumberSearch()` (the distinct repos across ALL
  loaded PRs, most-frequent first, capped at 6), so "jump to a PR by number" resolves in the
  repos you actually track (e.g. your busiest one) without pasting a URL. Debounced 350 ms
  (`Task.sleep` + a `searchQuery == rawQuery` recheck) so a number typed digit-by-digit only
  fans out once you pause, and it only fires when nothing local/prior already matches (the
  "No matching PRs" state). A number in a repo you track nowhere still needs the full URL —
  which the empty state nudges toward.

**Lifecycle.** Return hands focus back to the deck (filter kept) so J/K + pin work on the
results; Esc / ✕ / "Done" call `closeSearch()` (which also clears `searchFetchedPRs`). Closing
the popover itself also exits search: `KeyCaptureView`'s `onDismiss` (fired on window
`resignKey`) calls `closeSearch()` alongside clearing the peek, so reopening the panel starts
on the normal grouped deck.

### Preview deployment detection
Each PR can carry a `vercelPreviewUrl` extracted from a PR issue comment (REST `GitHubClient.fetchPreviewURL`, pure `extractPreviewURL(from:domains:linkLabels:)`). The row shows a `PreviewBadge` when present, and `E` (deck or peek, default binding — user-configurable) opens it via `TriageDeckView.openPreview` (silent no-op when absent). Enrichment is **lazy + cached** in `PRPoller.enrichVercelPreviews`: the URL is keyed on `PRSnapshot.vercelPreviewCheckedAt` (the `updatedAt` it was checked at), carried forward while `updatedAt` is unchanged, and re-fetched only when a new commit bumps `updatedAt` — so a steady poll makes ~zero extra REST calls. Applied via `PRStateStore.applyVercelPreviews` (patches + persists, never re-diffs — a preview is not a notifiable transition).

Detection is **not Vercel-specific** — a repo that rolls its own preview deploy in GitHub Actions posts under `github-actions[bot]`, not `vercel[bot]`, and the old hard-coded author filter dropped those comments before any URL match ran. Three user-editable settings now shape it (Settings → GitHub → Preview Deployments):

| Setting | Role |
|---------|------|
| `previewCommentAuthors` | Comment logins to scan, case-insensitive. **Empty = every author** (for a bespoke GitHub App). |
| `previewLinkLabels` | Substrings matched case-insensitively against a markdown link's *label*. |
| `vercelPreviewDomains` | Host suffixes, most-preferred first. |

`extractPreviewURL` matches in three tiers, last-match-wins within each: **(1)** a label-matched link whose *parsed host* is on a configured domain — where Vercel's `[Visit Preview](…)` and a custom `[Preview](…)` table cell both land; **(2)** a label-matched link on any other host minus `GitHubClient.nonPreviewHosts` (`github.com`, `vercel.com`, `vercel.live` — the dashboard/feedback/workflow-run links that sit *next to* a preview), which is what makes a bespoke preview domain work with zero config; **(3)** the original bare host-suffix regex scan, so a naked URL still resolves. `markdownLinks(in:)` skips images (`![alt](…)`) so a `![Ready](…/ready.svg)` status icon is never read as a link — *unless* the image is itself a link's label (`[![alt](img)](href)`), which a second pass captures by its outer href, using the alt text as the label; the two passes are merged by position, so callers still see document order. Domain matching goes through `URL.host`, not the raw string, so `github.com/acme/tree/vercel.app` can't satisfy a `vercel.app` suffix. Clearing both `previewLinkLabels` and `vercelPreviewDomains` disables enrichment; either one alone still works. `PreviewDetectionChecks.run()` (#if DEBUG, wired in `MainlineApp`) asserts the tiers against real Vercel + hand-rolled comment bodies — it covers the pure extractor only, not the author allow-list in the network path.

### PR open target (GitHub / Linear)
The primary "open" action (click / ↵ / `openInBrowser` verb) routes through `PRManager.openPR(_:)` (sync). GitHub by default. Linear is used only when the PR's repo passes `PROpenTarget.repoUsesLinear(repoFullName:filter:)` against `settings.linearRepoFilter` (a `[String]` allowlist of orgs `owner` or exact repos `owner/repo`; **empty = all repos**) — so work repos can open in Linear while personal repos stay on GitHub. When Linear applies it opens the PR's **review view** derived from the PR URL alone (no API key, no workspace slug): `PROpenTarget.linearDesktopURL(fromPRURL:)` builds `linear://linear.app/review/<owner>/<repo>/pull/<n>` — the `linear://` custom scheme is the only form that hands off to the Linear **desktop app** (the `/review/*` path is NOT in Linear's universal-link AASA, so `https` forms only ever open the browser). If the desktop app isn't installed (`NSWorkspace.open` returns false) it falls back to `PROpenTarget.linearWebURL(fromPRURL:)` = `https://linear.review/<path>` (Linear redirects it to the review page), then to the GitHub PR page. `openPR` records the `open_in_browser` interaction once, centrally. The peek card's Safari button (`PRPeekView`) always opens GitHub via `htmlUrl`.

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
| `githubUsername` | String | `""` — self-healing: `PRManager.start()` re-fetches it when empty (awaited) and re-verifies opportunistically when set. Load-bearing; see "Viewer identity". |
| `etag_<url>` | String | — |
| `writeActionsEnabled` | Bool | false |
| `mergeMethodPreference` | String | `auto` |
| `collapsedSectionsRaw` | [String] | [] |
| `snoozeMapData` | Data (JSON) | {} |
| `attentionPolicy` | [String: String] (`PREvent.rawValue` → `AttentionLevel.rawValue`) | `{}` — an ABSENT key falls back to `PREvent.defaults`, where `reviewRequested` and `reviewRequestedTeam` are `.notify` / `.quiet` respectively |
| `attentionPolicyMigrationVersion` | Int | `0` (absent) — last-applied `PREvent.policyMigrationVersion`; v1 clears a persisted `reviewRequested: quiet` |
| `panelHeight` | Int | 1600 |
| `panelMinHeight` | Int | 600 |
| `menuBarMetric` | String | `totalOpen` |
| `globalShortcutEnabled` | Bool | true |
| `globalShortcutKeyCode` | Int | `0x0A` (ISO section key) |
| `globalShortcutModifiers` | UInt | ⇧⌃ |
| `launchAtLogin` | Bool | false |
| `vercelPreviewEnabled` | Bool | true |
| `vercelPreviewDomains` | [String] | `["dash0-preview.com","vercel.app"]` |
| `previewCommentAuthors` | [String] | `["vercel[bot]","github-actions[bot]"]` — empty = scan every author |
| `previewLinkLabels` | [String] | `["preview"]` — case-insensitive substring match on a markdown link label |
| `telemetryEnabled` | Bool | false |
| `shortcutBindings` | Data (JSON) | `InAppShortcutBindings.defaults` — 17 `ShortcutBinding { key, modifiers }` entries; all bare except undo=⌘Z (`modifiers = NSEvent.ModifierFlags.command.rawValue`). Includes `markReady` (default `t`, bare — draft→ready write action; **moved off `f`**), `copyBranch` (default `c`, bare), `togglePin` (default `p`, bare — pin/unpin), and `search` (default `f`, bare — open search). Decoded with custom `Codable` that handles both the new object shape and the v1.25.0 legacy bare-string shape; undo bare-string → `.command` migration preserves ⌘Z; on the upgrade that introduces `search` (its key absent in stored JSON), a `markReady` still bound to bare `f` is relocated to `t` so `f` is free for search; absent fields fall back to factory defaults. |
| `pinnedNodeIds` | [String] | `[]` — nodeIds the user has pinned. A pinned PR appears in a dedicated **Pinned** subsection at the top of its role/tab group (a `.pinned` display-only `ActionGroup`, collapsible, expanded by default) with a pin glyph, and is ALWAYS visible: it overrides mute, the scope chip, and the Drafts toggle (but not snooze), and is fetched on demand (`node(id:)`) when it has dropped out of the live queries. Membership read via `settings.pinnedNodeIds`; toggled by the `togglePin` shortcut / context menu. |
| `unpinOnMerge` | Bool | `true` — when on, a PR auto-unpins once it has MERGED (not merely closed). Enforced by `PRManager.applyUnpinOnMerge`, run from the Done-set sink, the live-`prs` sink, and the on-demand pin fetch. Toggle in Settings → Appearance → Pinning. |
| `mutePatterns` | [String] | `["chore(deps)*", "build(deps)*"]` |
| `muteBotAuthors` | Bool | true |
| `botAllowList` | [String] | `[]` |
| `reviewFocusByOrg` | Data (JSON `[String: OrgFocusConfig]`) | `{}` |
| `muteLabels` | [String] | `[]` |
| `reviewNotReadyOnConflict` | Bool | true |
| `reviewNotReadyOnFailingCI` | Bool | true |
| `reviewNotReadyOnUnresolvedThreads` | Bool | true |
| `reviewNotReadyOnMyApproval` | Bool | true |

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
