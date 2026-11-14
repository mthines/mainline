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

## App icon

The source of truth is `docs/images/logo.svg` (the "Queue" mark: three stops on one line,
shrinking by priority, the top one green). `swift scripts/render-app-icon.swift` (from repo
root) redraws it with CoreGraphics into every `AppIcon.appiconset` PNG plus
`docs/images/logo.png` (the README logo). The script carries its own copy of the geometry —
keep it in step with the SVG when either changes.

## Architecture

```
Mainline.xcodeproj/                 ← Xcode project (at repo root)
Mainline/Mainline/                     ← Source root
├── MainlineApp.swift               ← @main, MenuBarExtra scene, AppDelegate
├── Models/
│   ├── PRSnapshot.swift         ← Canonical diff unit (one per PR); mergeable+headRefName+lines fields; `viewerHasApproved` (viewer's own latest review == APPROVED, from GraphQL `latestReviews`); `hasApproval` (a reviewer other than the author/viewer has an APPROVED latest review and nobody requested changes — badge-only fallback for `approvalBadge` when `reviewDecision` is null; never read by `readyToMerge`/`actionGroup`); `viewerIsCommitter` (viewer authored/co-authored one of the first 10 commits, from aliased GraphQL `commitAuthors`); `CommittedPRPlacement` enum; role-aware `actionGroup(splitDrafts:myLogin:reviewReady:)` + `needsMyTime(...)` + `ReviewReadyConfig`; `PRClassificationChecks.run()` #if DEBUG
│   ├── IssueSnapshot.swift      ← GitHub issue model + `IssueWatchLevel` (All issues / Only mine / Off), `IssueClassifier` (Needs you / Assigned / Waiting on reporter / Muted; `inboxItems` is the one source for badge + Inbox group), `IssueChecks.run()` #if DEBUG
│   ├── PRTransition.swift       ← Output of diff engine (4 cases)
│   ├── AttentionPolicy.swift    ← PREvent → AttentionLevel map (notify/quiet); `.defaults` (reviewRequested = notify); `isDeliverable`/`deliverable` SSOT for which events can actually fire; `PREventGroup` (Your PRs / PRs You Review) + `PREvent.group`; pure `migratedPolicy(from:storedVersion:)` + `policyMigrationVersion` for persisted-policy upgrades, each rule gated by stored version (v2 splits comments by role into `newCommentOnReviewPR`); `AttentionPolicyChecks.run()` #if DEBUG
│   └── MainlineSettings.swift      ← UserDefaults-backed settings + global-shortcut defaults; `InAppShortcut` enum + `ShortcutBinding` value type + `InAppShortcutBindings` custom-Codable struct for configurable deck/peek shortcuts (supports modifier combos ⌘⇧⌃⌥ per binding); `launchAtLogin` (SMAppService-backed launch-at-login toggle); pure `PanelBackdrop` (clamp + label for `panelBackgroundOpacity`) + `PanelBackdropChecks.run()` #if DEBUG ; `InAppShortcut.runPrompt` (default `a`) + `promptTerminal` (terminal for CLI prompt harnesses)
├── Services/
│   ├── KeychainHelper.swift     ← PAT storage (async, never blocks @MainActor); account-parameterized
│   ├── GitHubClient.swift       ← GraphQL search + mutations (approve / request changes / merge / mark ready / convert to draft / close / reopen) + REST diff/files; two-step `searchCommittedPRs` (light candidate search → `nodes(ids:)`) + `fetchPRStates` (carry-forward vetting); author now decoded with __typename for bot detection; labels(first:10) added Also `addComment(nodeId:body:token:)` (GraphQL `addComment`) for canned PR comments.
│   ├── PRStateStore.swift       ← @MainActor [nodeId: PRSnapshot] dict
│   ├── PRDiffEngine.swift       ← Pure diff(previous:next:myLogin:)
│   ├── IssueDiffEngine.swift    ← Pure issue diff (newIssue/assigned/mentioned/reply, 3-day new-issue max age) + `carryingForward` for incomplete fetches; `IssueDiffChecks.run()` #if DEBUG
│   ├── IssueStore.swift         ← @MainActor issue poll (involves:@me + chunked org:/repo: broad queries), persisted baseline `issue-snapshots.json` (first run seeds silently), unread/mute sets in settings, counts-only telemetry
│   ├── PRPoller.swift           ← Task-based poll loop + pollOnce(); pure `carryingForward(fetched:previous:incompleteTabs:)` → `CarryForwardResult` keeps a 304 / 5xx / degraded-page tab from shrinking the diff baseline and counts what it rescued (`mainline.poll.carried_forward`); pure `droppingFinished(_:states:)` drops carried PRs GitHub reports merged/closed; `CarryForwardReason` enum; `PollCarryForwardChecks.run()` #if DEBUG
│   ├── NotificationService.swift← UNNotificationRequest per transition; `async requestAuthorization()` returns `(granted, error)`; comment transitions route by role (`newReviewOrComment` on your work, `newCommentOnReviewPR` otherwise); `authorizationState()` + pure `classify(...)` → `NotificationAuthorizationState`; `openSystemNotificationSettings()`; case-insensitive `resolveTransition` via `PRSnapshot.loginsMatch`; `NotificationRoutingChecks.run()` #if DEBUG
│   ├── PRManager.swift          ← @MainActor orchestrator + write actions; inbox-derived populations (inboxActivePRs, inboxMutedPRs, inboxMuteConfig); currentViewPRs routes to inboxActivePRs on .inbox tab; self-healing `refreshUsername` (nonisolated fetch + `UsernameFetchError` + published `usernameError`); published `notificationAuthorization` via `refreshNotificationAuthorization()`; published `notificationRequestError` (why a Settings-driven permission request was rejected) ; `promptStore`, `@Published promptPickerTarget`, `runPromptTemplate` / `runCustomPrompt` Comment templates: `commentStore`, `@Published commentPickerTarget`, `postComment(_:label:on:)`.
│   ├── SensitivePathMatcher.swift ← Pure path/branch-name heuristic classifier
│   ├── TriageClassifier.swift   ← Pure needsHuman predicate engine
│   ├── PRSearchFilter.swift     ← Pure search matcher (number / PR-URL / free-text); `matches(_:query:)` + `runSelfChecks()` #if DEBUG
│   ├── PRListExport.swift       ← Pure Markdown formatter for a section's PRs (URL + CI/review/draft/conflict/threads/size/branch per PR), copied by the hover button on deck section headers and expanded stack headers; `PRListExportChecks.run()` #if DEBUG
│   ├── PromptTemplate.swift     ← Pure prompt-template engine: `PromptTemplate` (`harness` = default + `extraHarnesses`, per-harness `harnessBodies` from `--- harness: <key>` sections, `resolved(for:)`) / `HarnessConfig` / `PromptConfig` models, frontmatter `parse`/`serialize`, `runnableHarnesses` / `effective`, `validate` (a harness's command/url MUST contain `{{prompt}}`), single-pass `substitute`, `launch(...)` → `.web(URL)` or `.terminal(script:promptText:)`, `filter`, `PromptStarters`; `PromptTemplateChecks.run()` #if DEBUG
│   ├── CommentTemplate.swift    ← Pure canned-PR-comment engine: `CommentTemplate` (`scope` = `owner/repo` / `owner/*` / `*`, empty = everywhere; `when:` / `priority:` reuse `PromptState`), `CommentEngine` (`parse`/`serialize`, `patternMatches`/`appliesTo`, `validate` — only `{{pr.*}}`, `render`, `ordered` = scoped then suggested-first, `filter` over the name only), `CommentStarters.readme`; `CommentTemplateChecks.run()` #if DEBUG
│   ├── CommentTemplateStore.swift← @MainActor owner of `~/.config/mainline/comments/*.md` (seeds the folder + README only, NO starter comments; 2s signature poll; `revision` folded into `DeckRowKey`)
│   ├── PromptTemplateStore.swift← @MainActor owner of `~/.config/mainline/` (`config.json` + `prompts/*.md`, seeded on first run, 2s signature poll for live reload); `PromptTerminal` enum; `PromptLauncher` (writes a temp `.command` script + prompt file, opens terminal/browser)
│   ├── InboxMuteEngine.swift    ← Pure glob matcher + four mute-rule predicates (pattern/botAuthor/label/outsideFocus); InboxMuteConfig + per-org OrgFocusConfig value structs; muteVerdict takes the PR's `org`; runSelfChecks() #if DEBUG
│   ├── ScopeStore.swift         ← @MainActor derives org/repo scopes from PR list; drives badge
│   ├── StackEngine.swift        ← Pure stacked-PR detection: chains where `B.baseRefName == A.headRefName` (same repo) become a `Stack` (bottom→top); `detect(_:)` + `Index` (`stack(containing:)` / `isStacked` / `position(of:)`); `StackEngineChecks.run()` #if DEBUG
│   ├── SnoozeStore.swift        ← @MainActor snooze wrapper over MainlineSettings
│   ├── GlobalHotKey.swift       ← Carbon global hotkey + MenuBarPopoverOpener
│   └── TelemetryService.swift   ← Opt-in OTel singleton (no-op when disabled)
│   └── LaunchAtLoginService.swift ← SMAppService-backed launch-at-login registration (pure enum, no I/O on the main thread)
└── Views/
    ├── MenuBarView.swift         ← MenuBarExtra panel; single actionability-grouped TriageDeckView; passes mutedPRs + inboxMode to TriageDeckView on .inbox tab; `panelBackdrop` paints the user-configurable opaque layer over the window's system material (`settings.panelBackgroundOpacity`, no-op at 0) ; hosts the prompt-picker overlay (bound to `promptPickerTarget`) Also hosts the comment-picker overlay (bound to `commentPickerTarget`).
    ├── SettingsView.swift        ← PAT entry, gh import, toggles, write-actions, shortcut recorder, panel min/max height, panel background-opacity slider; includes `.inbox` SettingsCategory routing to InboxSettingsView and `.keyboard` routing to KeyboardShortcutsView; GitHub pane shows the resolved login + `usernameError`; Notifications pane shows the macOS-permission warning with a state-aware CTA (`.notDetermined` → "Enable Notifications…" calling `requestNotificationAuthorization()`, with a `notificationRequestError` caption beneath it; `.denied`/`.silent` → "Open System Settings…") and groups the Attention Policy list into per-role sections via `PREventGroup.events` (filters `PREvent.deliverable`) ; `.prompts` category routing to `PromptsSettingsView` Also `.comments` category routing to `CommentsSettingsView`.
    ├── IssuesView.swift          ← Issues tab: Needs you / Assigned / Waiting on reporter + collapsed Muted; row context menu sets per-repo watch level
    ├── IssuesSettingsView.swift  ← Settings → Issues: "Show new issues in Inbox" toggle, per-org and per-repo watch level (All issues / Only mine / Off)
    ├── InboxSettingsView.swift   ← Inbox noise-filter settings: Review Readiness (four reviewer "not ready → Waiting" toggles: conflict / failing CI / unresolved threads / approved-by-me, all default ON), mute patterns, muteBotAuthors toggle, per-org Review Focus (org sub-blocks nested INSIDE the one Review Focus card via `orgFocusBlock`, each with a Remove button; authors+teams keyed by lowercased org, derived from `manager.knownOrgs` + saved config + an add-org field), muteLabels
    ├── PromptPickerView.swift    ← Panel-level type-to-filter picker (↑/↓ ↵ Esc, ←/→ = harness of a multi-harness template, Tab = stack ↔ this PR) over templates + one free-typed "Ask" row (chips for each harness, ←/→ switch); opened by the `runPrompt` key (default A) or the row menu's "Run Prompt ▸ Search / Custom Prompt…"
    ├── CommentPickerView.swift   ← Panel-level type-to-filter picker (↑/↓ ↵ Esc) over the comments scoped to ONE PR's repo + a "Post as typed" row; previews the exact text ↵ will post; opened by the `addComment` key (default W) or the row menu's "Comment ▸ Search / Custom Comment…"
    ├── CommentsSettingsView.swift← Settings → Comments: list + editor (name, scope, when, priority, body), New / Open Folder / Reload
    ├── PromptsSettingsView.swift ← Settings → Prompts: terminal picker, template list + editor (New / Open Folder / Reload; harness picker + "Also offer on" toggles + per-harness prompt fields), harness status, Open config.json
    ├── KeyboardShortcutsView.swift ← Configurable deck/peek shortcuts UI: per-action `InAppShortcutRecorder`, clash detection, Reset All button
    ├── MenuBarIconView.swift     ← Dynamic badge: MenuBarBadge enum → SF Symbol + tint
    ├── TriageDeckView.swift      ← Keyboard triage (J/K/Space/↵/E/A/W/M/T/R/S/N/X/V/D/Q/C/P/F/⌘Z) + TriageAction enum + per-row context menus (`rowContextMenu` for deck + Postponed rows, `doneRowContextMenu` for Done rows; see "Write actions") + hover-revealed section-header and stack-header copy button (`copyPRList` → `PRListExport`) + first-responder KeyCaptureView; deck keys are user-configurable via settings.shortcutBindings; Inbox mode: role sections (yourPRs / needsYourReview) + collapsed Muted group; Q toggles per-PR manual mute (settings.inboxMuteOverrides); T marks draft PR ready for review (draft-only, write-gated, plain toast); P pins/unpins the focused PR (floats it to the top of its group, `settings.pinnedNodeIds`); F opens the search bar (flat results view, `searchMode`, once a query is typed) `W` opens the comment picker (`addComment`, write-gated); right-click Comment submenu (`commentMenu`, confirms via alert).
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

Carrying forward is blind, so every carried PR is then **vetted**: one cheap
`GitHubClient.fetchPRStates` (`nodes(ids:) { id state }`) lookup, and the pure
`PRPoller.droppingFinished(_:states:)` removes any carried PR GitHub now reports
`MERGED` / `CLOSED`. Without it, a query that stays incomplete poll after poll keeps
its merged PRs on screen as "open" forever — an `is:open` search can never return
them to clear them. Unknown is not finished: a PR missing from the lookup (failed
request, unresolvable node) is kept. Dropped PRs are counted in
`mainline.poll.carried_forward_dropped`.

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
   Surfaced as a warning in Settings → Notifications, backed by
   `PRManager.notificationAuthorization`. **The CTA is state-aware:** `.notDetermined`
   gets an **"Enable Notifications…"** button that calls
   `PRManager.requestNotificationAuthorization()` (request → refresh) — the one state
   System Settings can't fix, since there's nothing to toggle until the app has asked.
   That matters because notification grants are keyed by **code signature**, not just
   bundle ID, and the launch-time `requestAuthorization` in `start()` fires while this
   menu-bar accessory is INACTIVE, so its prompt is often never presented — leaving the
   signed release stuck `.notDetermined` even while System Settings shows a provisional
   "Allow" row. Requesting from the Settings window (app active → prompt shows, or an
   already-granted state resolves without one) clears it. `.denied` / `.silent` instead
   get "Open System Settings…". `requestAuthorization()` is `async` and no longer
   discards `granted`; it also returns the request's `error`, which Settings shows as
   `PRManager.notificationRequestError`. A request rejected with **no prompt** almost
   always means a broken bundle signature — CI builds without a Developer ID must be
   ad-hoc signed (`scripts/release-ci.sh`, see `docs/release.md`).
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
   `PREvent.migratedPolicy(from:storedVersion:)`, run once from the trailing block of
   `MainlineSettings.init()`. v1 REMOVES a stored `reviewRequested: quiet` (removal, not
   overwrite, so future default changes also land) while preserving a deliberate `off`.
   v2 copies a stored `newReviewOrComment` level to `newCommentOnReviewPR` (the
   comment event was split by role — see below).

The Settings pane groups the rows by `PREvent.group` (`PREventGroup`: **Your PRs** /
**PRs You Review**, mirroring the deck's role split); `group` is exhaustive like
`isDeliverable`. Comments are routed by role: `.newReviewOrComment` on your own work
(`isViewersWork`), `.newCommentOnReviewPR` on anyone else's.

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
`AttentionPolicyChecks.run()`, `NotificationRoutingChecks.run()`, `StackEngineChecks.run()`,
`PanelBackdropChecks.run()`, `PRListExportChecks.run()`, `PromptTemplateChecks.run()`, `CommentTemplateChecks.run()`. Add new pure logic's
assertions to one of these (or a sibling enum in the same file) rather than introducing a
test framework. Keeping the decision table pure — `PREvent.migratedPolicy(from:storedVersion:)`,
`NotificationService.classify(...)` — is what makes it assertable at all.

### Write actions
Write actions (Approve, Merge, Request Changes, Mark Ready, Convert to Draft, Close, Reopen) are gated by `settings.writeActionsEnabled` (default OFF). Each is a `WriteAction` case handled in `PRManager.performAction` (GraphQL mutation in `GitHubClient` → `recordWriteAction` telemetry → `presentActionFailure` on error → `triggerSingleRefresh`). Always show an `NSAlert` confirmation before calling the GitHub API — via `TriageDeckView.dispatchVerb` + `confirmCopy`. The two deliberate exceptions are the draft-state pair, Mark Ready and Convert to Draft, which fire immediately with a plain toast because each reverses the other. Posting a canned comment (see "Comment templates") is gated the same way but is not a `WriteAction`: it goes through `PRManager.postComment`, with its own confirmation. Close is menu-only and never gets a default key.

**Row menus.** Every row kind has a right-click menu. Deck rows AND Postponed rows share `rowContextMenu(for:)` — GitHub write verbs, triage verbs (Later ↔ Resume when `snoozeStore.isSnoozed`), view/open (plus Open on GitHub when `prOpenTarget == .linear`), copy (link, branch), Run Prompt (see Prompt templates), Comment (canned comments scoped to the PR's repo, `commentMenu`), then Close PR (destructive role) or Reopen PR for a closed-unmerged pin. Done rows use the smaller `doneRowContextMenu(for:)` (open, copy, Reopen for closed-unmerged). Section headers (actionability groups and the Inbox role headers) reveal a copy button on hover — also a "Copy PR List" and a "Run Prompt on <section>" right-click item — that copies the section's PRs, stack members included, as a Markdown list via `PRListExport` (`TriageDeckView.copyPRList`; hover state lives in a per-header `HoverReveal` so it never re-renders the deck). An expanded stack's header (`stackHeader`) carries the same button + menu item for just that stack's `members`, bottom → top. A new triage verb belongs in `TriageAction` + `handleTriageAction` + the relevant menu, so the right-click menu stays the discoverable home for every action.

### Keyboard events in MenuBarExtra
`.onKeyPress` requires macOS 14+ (deployment target is 13). A local `NSEvent` monitor only fires while the app is *active*, and clicking the menu bar icon does NOT activate an accessory app — so key nav silently died on click-open. Instead `TriageDeckView` embeds a zero-size first-responder `NSView` (`KeyCaptureView`) that overrides `keyDown`: it receives keys whenever the popover window is key, independent of app-active state. It also handles Esc-to-close (the first responder otherwise swallows the popover's built-in Esc dismissal).

All 19 in-popover deck/peek action keys are **user-configurable** via Settings → Keyboard (`KeyboardShortcutsView`). Each binding stores a base key AND a modifier set (⌘⇧⌃⌥) as a `ShortcutBinding { key: String, modifiers: UInt }` value type — `modifiers` mirrors the global-hotkey's `NSEvent.ModifierFlags.rawValue` storage. `handleKeyDown` reads bindings from `settings.shortcutBindings` at runtime via `shortcutMatches(_:event:)`, which compares BOTH the base key (from `charactersIgnoringModifiers`) AND the masked modifier flags — never hardcoded literals. Default bindings: E=preview, A=runPrompt (prompt-template picker), W=addComment (canned-comment picker, write-gated), N=markSeen, Q=toggleMute (Inbox mute / move-up), T=markReady (draft→ready, write-gated, plain toast), C=copyBranch (copies `headRefName` to the clipboard + info toast; silent no-op when empty), P=togglePin (pin/unpin the focused PR), F=search (opens the search bar; flat results once a query is typed), J/K/Space/M/R/S/X/V/D bare; **undo=⌘Z** (⌘ stored in the binding, not a hardcoded branch). **Left-hand default policy:** new in-app shortcut *defaults* should favour left-hand keys (Q W E R T A S D F G Z X C V B) so the deck is usable one-handed while the pointing hand stays on the trackpad/mouse. (Vim-convention J/K nav and the mnemonic M/N, P=pin, F=find are deliberate exceptions; anything reached frequently should default left-hand. Users can always rebind.) The `InAppShortcutRecorder` captures modifiers alongside the key (mirroring `ShortcutRecorder` but without the non-empty-modifier guard, since bare keys are valid in-app). Persisted as JSON in UserDefaults (`shortcutBindings`); the custom `Codable` decodes BOTH the new `ShortcutBinding` object shape and the v1.25.0 legacy bare-string shape. Migration rules: (1) a v1.25.0 `undo` bare string gets `.command` applied so ⌘Z is preserved on upgrade; (2) when `search` is introduced (its `.search` key is ABSENT in the stored JSON = an upgrade), `search`'s default key `f` collides with the old `markReady` default `f`, so a `markReady` still bound to bare `f` is relocated to its new default `t` to free `f` for search — a `markReady` the user deliberately rebound elsewhere is left untouched. This migration is re-derived on every launch (idempotent; it never needs to persist to be correct). All other bare-string fields decode with empty modifiers.

### Global shortcut
System-wide hotkey to open the popover, via Carbon `RegisterEventHotKey` in `GlobalHotKey`. Stored as `globalShortcutKeyCode` + `globalShortcutModifiers` (Cocoa `NSEvent.ModifierFlags` raw value; converted to a Carbon mask by `GlobalHotKey.carbonModifiers(from:)`). `AppDelegate.setUpGlobalHotKey()` subscribes to the three `MainlineSettings` published props so the recorder, toggle, and reset button all live re-register. The recorder UI (`ShortcutRecorder` + the "Global Shortcut" section) lives in the **Keyboard** settings pane (`SettingsView.keyboardSection`), directly above the in-app `KeyboardShortcutsView` — so every keyboard binding, global and in-app, sits in one place. Default: **⇧⌃ + ISO section key** (`kVK_ISO_Section` = 0x0A; the "$" key on a Danish layout) — see `defaultShortcutKeyCode`/`defaultShortcutModifiers`. `keyGlyph(for:)` renders the key label, falling back to `UCKeyTranslate` against the active keyboard layout for non-ANSI physical keys.

### Role-aware actionability

`PRSnapshot.actionGroup(splitDrafts:myLogin:reviewReady:)` is the single source of truth for section grouping, and it is **role-aware** — the top section means opposite things for a PR you authored versus one you were asked to review. Role comes from `inboxRole(myLogin:)` (`author == myLogin`).

- **Author role (your PRs)** — three buckets: `.needsAttention` (blocked on you: failing CI, changes requested, unresolved threads, **or merge conflict** — conflicts count here, unlike the role-agnostic `needsAttention`), `.readyToMerge` (approved + mergeable + green), `.waiting` (blocked on reviewers/CI).
- **Reviewer role (assigned to you)** — two buckets: `.readyForReview` (genuinely ready for your eyes) and `.waiting` (author still owns it). `readyForMyReview(_:)` gates readiness on `changesRequested` (always) plus four **user-configurable** signals in `ReviewReadyConfig` (merge conflict, failing CI, unresolved threads, `viewerHasApproved`), all default ON, edited in Settings → Inbox → Review Readiness and stored as four bools on `MainlineSettings` (`reviewReadyConfig` assembles them).

**PRs you committed to but did not open** (`viewerIsCommitter`, e.g. a bot/agent opening your PR as `dash0-dev[bot]`) follow `settings.committedPRPlacement` (Settings → Inbox → PRs You Committed To), threaded into `inboxRole` / `actionGroup` / `needsMyTime` as `committedPlacement:`: `.yourPRs` (default) makes `inboxRole` return `.yourPRs`; `.prioritizedReview` keeps the reviewer role but `isPrioritizedCommit` floats it to the top of its section (`TriageDeckView.orderWithStacks`); `.standard` = author-only, as before. In the first two modes `exemptFromMuteRules` skips every Inbox mute rule (a manual `Q` override still wins). GitHub search has no "has my commits" qualifier, so discovery is opt-in: `settings.committedPRBotAuthors` makes `PRPoller` run one extra committed-PR fetch per poll (`committedPRQuery` → `is:open is:pr sort:updated-desc author:app/<bot> …`) and keep only `viewerIsCommitter` results, always tagged `.created` (a placement-dependent tag would re-tag them into For me and fire `.readyForReview` on every placement change), telemetry `poll.query_type="committed"`. That search returns every PR the bot opened for ANYONE, so it runs through `GitHubClient.searchCommittedPRs` in two steps — a light search selecting only `id` + `commitAuthors` (the shared `commitAuthorsField`), then the full `prNodeFields` via `nodes(ids:)` for just the viewer's PRs. The light search pages (`after:` / `pageInfo`) up to `committedSearchMaxPages` (5) — a busy bot has more than one 100-node page — and results left unread at the cap are reported `degraded`, so they carry forward rather than drop. A single full-field search over 100+ bot PRs blew GitHub's time budget on most polls, and its degraded half-page made the bot's merged PRs carry forward indefinitely. The first complete poll after a bot is added SEEDS its PRs (`seedingBots` — `.newPR` suppressed) rather than announcing them. Its carry-forward is by SOURCE (`incompleteCommittedQuery` + `isCommittedBotPR`), never by tab — a 304 on it must not keep PRs that left the shared tab's regular query. `PRSnapshot.isViewersWork` (author, or committer unless `.standard`) makes a committed PR notify as `.newPRByMe`, fire CI banners, and count in `needsYouCount`.

`.needsAttention` and `.readyForReview` share sortIndex 0 (they never coexist in one role's section list). The menu-bar "needs attention" badge (`PRManager.needsAttentionPRs`) now counts the role-aware `PRSnapshot.needsMyTime(myLogin:reviewReady:)` — author-role blocked-on-you PLUS reviewer-role ready-for-you — so the count means "needs my time" across both roles. `viewerHasApproved` is fetched via GraphQL `latestReviews(first:20)` matched against the authenticated login at map time (`GitHubClient.makeSnapshot` takes `myLogin`); it decodes with a `false` default and is excluded from `PRDiffEngine`.

### Inbox / review focus

The **Inbox tab** (`ReviewTab.inbox`) is a client-side derived union of the forMe + created queries. `PRManager` deduplicates by `nodeId`, then passes each snapshot through `InboxMuteEngine.muteVerdict(...)` — nil = active (shown in role sections), non-nil = muted (collapsed Muted group at the bottom). Four mute rules apply in priority order: (1) glob patterns on title+branch via `InboxMuteConfig.mutePatterns`, (2) bot-author detection (`muteBotAuthors`) with per-bot exemptions via `botAllowList`, (3) label matching (`muteLabels`), (4) **per-org** focus allow-list (`InboxMuteConfig.focusByOrg`, built from `settings.reviewFocusByOrg: [String: OrgFocusConfig]`). Rule 4 looks up ONLY the PR's own org (case-insensitive) via `InboxMuteEngine.focusConfig(for:in:)`: an org with no entry — or an empty one — has no focus rule, so all its PRs stay active, and a focus rule scoped to one org never mutes PRs in another (this replaced an earlier global-focus model where an org-local team slug like `ai` silently muted unrelated orgs' PRs). Rule 4 is also skipped for `.yourPRs` role — your own PRs are never muted by focus. The pre-per-org global keys (`reviewFocusAuthors`/`reviewFocusTeams`) are left on disk but NOT migrated into an all-orgs rule (that global apply-everywhere behavior was the bug); focus starts empty and is re-declared per org. GraphQL now fetches `author { __typename login }` (for bot detection via `__typename == "Bot"`) and `labels(first: 10) { nodes { name } }`. New `PRSnapshot` fields (`labels`, `authorIsBot`) decode with `decodeIfPresent` so old persisted snapshots are backward-compatible; neither field triggers a diff-engine transition (excluded by omission from `PRDiffEngine`).

### Stacked PRs

A **stack** is a chain of open PRs where each PR's base branch is another open PR's head
branch, **in the same repo** — `B.baseRefName == A.headRefName` means B is stacked on A.
Detection is the pure `StackEngine` (`Services/StackEngine.swift`): `detect(_:)` returns
`[Stack]` (members ordered **bottom → top**, base-most first — the merge order) and `index(_:)`
wraps them in a `StackEngine.Index` for O(1) per-row lookups (`stack(containing:)`, `isStacked`,
`position(of:)`). Rules: only OPEN PRs link (a
merged/closed base is not a live link — GitHub retargets the child, so it becomes its own
root); branches are keyed per repo (`repoFullName` + ref) so fork branch-name collisions don't
cross-link; a stack needs ≥ 2 members; detection only sees the PRs it is handed, so a chain
split by a filter/unwatched repo degrades gracefully. `baseRefName` was added to
`GitHubClient.prNodeFields`, `GraphQLNode`, and `PRSnapshot` for this (decodes with a `""`
default; NOT compared in `PRDiffEngine` — a rebase is not a notifiable transition).
`StackEngineChecks.run()` (#if DEBUG) asserts ordering, cross-repo isolation, merged-base
break, forks, and the lookup helpers.

**Rendering (`TriageDeckView`).** A stack renders as ONE collapsible **card** placed by its
**bottom** PR's actionability group (stacks merge bottom-up, so the base is the actionable one).
`effectiveGroupFor(_:)` routes every member to the bottom's `groupFor` group, and
`orderWithStacks(_:)` keeps members contiguous + bottom→top at the bottom's triage slot — so
`sectionsWithPinned`, `orderedPRs`, and the on-screen layout never diverge.
- **Collapsed** (default expanded, state persisted under a `"stack:<id>"` key in
  `collapsedSectionsRaw`, which never decodes to an `ActionGroup`): a normal, fully-aligned
  `deckRow` for the base PR, with a `chevron.right` in the **status-icon slot** (in place of the
  CI icon) and a `⛚ N` count chip in the subline. It acts as a disclosure — the row's tap
  (`deckRow(onRowTap:)`) and Return expand the stack rather than opening the base — and is a
  SINGLE J/K stop (`isKeyboardVisible` keeps only the base while collapsed).
- **Expanded**: a compact `Stack (N) · #x → #y` header + each member as a `deckRow` behind a
  connector spine (`stackSpine`, indent `stackSpineWidth`), tagged with a `1/N` position chip
  (`deckRow(stackBadge:)`); every member is its own J/K stop.
`deckItems(for:prs:stacks:)` folds a section's flat list into `.row` / `.stack` render items;
Postponed/Done/Muted never stack. Styling is grey/secondary throughout (no accent color).

**Group actions.** A stack moves as a unit: `TriageDeckView.stackMembers(of:)` expands any
member to the whole stack, so **pin** pins/unpins all members together (they float to Pinned as
one unit) and **postpone/resume** (`S` / Later) parks/wakes all members together. Both wrap the
whole-stack change in a single `pushUndo`. The expanded stack header's hover copy button
(and its "Copy PR List" right-click item) copies all members, bottom → top, via `copyPRList`.

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

**Pins are always visible — within the selected org.** A pin means "keep this in front of me,"
so it overrides the noise filters — but NOT snooze (an explicit "later" wins), and by default
NOT the org chip either. `PRManager.effectiveMuted` returns
`false` for a pinned PR (overriding both mute rules AND a manual mute override), so a pinned PR
pops OUT of the collapsed Muted group into its natural role/actionability section; the Drafts
toggle (`inboxUnionPRs`, `tabFiltered`) likewise keeps a pinned PR regardless. It then surfaces
in the dedicated Pinned subsection at the top of its role/tab group (see **Pinning** above).

The **scope chip is the one filter a pin does not override by default**. Both scope pipelines —
`applyingSelectedScope` (Inbox) and `tabFiltered` (For me / Created) — route through the single
`PRManager.survivesScope(_:scope:)` predicate, which keeps an out-of-org pin only when
`settings.pinsIgnoreOrgFilter` is ON (default OFF). Org-scoped is the default because the
opposite reads as a bug: selecting `mthines` while four pinned `dash0hq` PRs sat at the top of
the deck made the Pinned section the one block that ignored the chip, and left the chip's count
("mthines 5") disagreeing with the rows on screen — the chip counts come from the
scope-INDEPENDENT base (`scopeSelectorBasePRs`), so each pin counts under its own org either way.
Only the scope chip is affected; mute, Drafts, search (`searchBasePRs` ignores the chip on
purpose) and the on-demand pin fetch are unchanged. `refreshPinnedFetches` deliberately still
fetches pins the chip currently hides — the chip can change between polls, and gating the fetch
on it would blank the deck for a poll after switching chips and under-count the hidden org.
**On-demand fetch:** a pinned PR can
also fall out of the live For me / Created queries entirely (nothing to float). `PRManager`
keeps a `pinnedFetchedPRs` cache reconciled by `refreshPinnedFetches()` (run on every poll via
the `store.$snapshots` sink, and on `togglePin` / `setPinned`): it prunes entries that are
unpinned or reappeared live, then **(re-)fetches EVERY pinned nodeId that isn't live — including
ones already cached** — via `GitHubClient.fetchPRByNodeId(nodeId:token:)` (GraphQL `node(id:)`
reusing `prNodeFields` → `makeSnapshot`; tab membership derived from role — author → Created,
else For me), **upserting the fresh snapshot in place**. Re-fetching (not just fetching the
missing ones) is what keeps a fetched pin's state — CI, reviews, mergeability — as current as a
live PR's; without it a pin that has dropped out of the live queries freezes at its first-fetch
snapshot and never refreshes on subsequent polls. A pin still in the live queries refreshes for
free through the normal poll, so only the non-live pins cost an extra `node(id:)` call each poll.
Each freshly-fetched pin is then run through `pinnedPreviewEnriched(_:token:)`, which sets its
`vercelPreviewUrl` exactly as `PRPoller.enrichVercelPreviews` does for live PRs (same feature gate
+ match-rule guards, same `vercelPreviewCheckedAt`-keyed carry-forward so a steady poll makes no
extra REST call) — without it an on-demand-fetched pin never flows through the poller's enrichment
and so shows no preview badge and `E` does nothing.
Results merge into every population through the `prsIncludingPinned` source. Guards:
`pinnedFetchInFlight` (no double-fetch), `pinnedUnfetchable` (negative-cache so an unfetchable pin
isn't refetched each poll; cleared when unpinned). Because `fetchPRByNodeId` returns `nil` for BOTH
a genuinely deleted node AND a transient non-FORBIDDEN GraphQL error at HTTP 200 — indistinguishable
to the caller — a `nil` only negative-caches when the pin was **never** successfully fetched (a
first fetch that failed); for an **already-cached** pin a `nil` (like a thrown transient error)
keeps the last-known snapshot and retries next poll, so a GraphQL blip can't permanently hide a
still-valid pin (the "pins are always visible" invariant). The upsert is guarded by `!=` so an
unchanged pin doesn't fire `objectWillChange` every poll. Silent on failure — an unreachable
never-cached pin just won't surface.

**Search.** The `search` shortcut (default `F`) sets `PRManager.searchActive`, which makes
`MenuBarView` render a search `TextField`. The deck stays on the normal grouped view while the
query is EMPTY (an empty query matches every PR, and swapping to the flat list built a row per PR
eagerly — a ~0.5–1s lag on open); only once something is typed (`MenuBarView.searchFiltering`)
does it switch into `searchMode`: a single FLAT "Results" list (no grouping, no
Postponed/Done/Muted), pinned first. `TriageDeckView.searchActive` (bar open) is distinct from
`searchMode` (query non-empty) and drives focus-hiding, the Up-to-field handoff, and resetting
`selectedIndex` to 0 on open. `KeyCaptureView` reclaims first responder when search closes —
otherwise the removed field editor leaves nothing to take the next key and F beeps. Focus is driven by
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

**Arrow focus handoff.** The search field sits directly above the deck (the flat results once a query is typed), so the two
navigate as one column: pressing **Down** in the field hands focus to the deck (→
`searchFieldFocused = false`) so the row shortcuts (pin, snooze, …) act on the first result,
and pressing **Up** (or the configured nav-up key) on the FIRST row returns focus to the field
(`handleKeyDown` bumps `manager.searchFocusToken`, which `MenuBarView` observes to refocus).
Down can NOT be caught with `.onMoveCommand` — a single-line `NSTextField` treats Down as
"move cursor to line-end" and consumes it, so SwiftUI never sees the command. Instead
`MenuBarView` installs a local `NSEvent` key monitor (`installSearchDownMonitor`) **only while
the field is focused** that intercepts keyCode 125 (Down), consumes it (returns nil, so the
cursor stays put), and defers `searchFieldFocused = false` one runloop tick. It touches only
the Down key — typing (incl. a bare `j` into the query), ←/→ cursor, Up, Return and Esc all
pass through — and is torn down on blur / search-close / disappear (`removeSearchDownMonitor`).
While the field holds focus, NO row shows the keyboard-focus highlight: `MenuBarView` passes
`searchFieldFocused` into `TriageDeckView`, whose `showsKeyboardFocus` (`!(searchActive &&
searchFieldFocused)`) gates BOTH the visual (`deckRow`) and the `DeckRowKey` memo, so the top
result isn't highlighted until Down actually moves focus into the list (and it hides again on
the Up-from-first-row handoff back to the field).

**Lifecycle.** Return hands focus back to the deck (filter kept) so J/K + pin work on the
results; Esc / ✕ / "Done" call `closeSearch()` (which also clears `searchFetchedPRs`). Closing
the popover itself also exits search: `KeyCaptureView`'s `onDismiss` (fired on window
`resignKey`) calls `closeSearch()` alongside clearing the peek, so reopening the panel starts
on the normal grouped deck.

### Prompt templates (agent harnesses)

Right-click a PR → **Run Prompt ▸ <template>** (or press `A`, `runPrompt`) starts an agent session for it. Files are the source of truth, in `~/.config/mainline/`:

- `prompts/*.md` — one template each: frontmatter (`name`, `harness`, `checkout`; `#` comment lines ignored) + body with `{{pr.url|number|title|repo|owner|branch|base|author}}`. Seeded on first run only when the folder is missing (deleting a starter sticks); `README.txt` documents the format.
- `config.json` — `harnesses` (key → `{label, command}` for a terminal CLI, or `{label, url}` for the browser; optional `"enabled": false` hides + refuses it), `order` (harness keys by priority, first = default — the one a free-typed prompt asks first; unlisted keys follow by label; edited from Settings → Prompts via toggle + ↑/↓, which rewrites `config.json` unless it currently fails to parse), `repoUrls` (`owner/repo`, `owner/*` or `*` — exact beats org beats `*` — → harness key → url template replacing a WEB harness's `url` for that repo, applied in `PromptLauncher.run` via `PromptConfig.resolved(forRepo:)`; must keep `{{prompt}}`, e.g. Agent0 on dev + a specific org), `repos` (`owner/repo` → local clone; CLI harnesses start there, else `~`), `checkout` (pre-step run when a template sets `checkout: true`, default `gh pr checkout {{pr.number}}`).

**Multiple harnesses per template.** `harness:` may list several keys, comma-separated; the first is the default, the rest are `extraHarnesses`. A body section starting `--- harness: <key>` overrides the prompt for that harness (`resolved(for:)`). In the picker a template row shows a chip per harness and ←/→ switch it — while the query is empty, or when the caret is already at the edge the arrow points to (→ at the end, ← at the start, no selection), so the arrows keep moving the cursor in typed text. The free-typed Ask row's harness chips switch the same way. The row menu gets a per-harness submenu, and Settings → Prompts edits it via "Also offer on" toggles plus a per-harness prompt field (changing the default harness drops it from the extras).

**State-based suggestions.** A template's optional `when:` (an expression over PR-state tokens: `,` = or, `+` = and, `!` = not — e.g. `authored+conflict, authored+ci-failing`) and `priority:` (higher first, default 0) float it to the top of the picker (starred, "Suggested: <matched alternative>") and the row menu when the PR is in that state; the rest keep file order, templates without `when:` are never floated. Pure `PromptState` (`active(pr:myLogin:)` → token set, `parse`, `matchedAlternative`, `ordered`); an unknown token is a validation error. Starters: Resolve merge conflicts (30), Fix failing CI (20), Address review feedback (15), Review PR (10), Analyse telemetry / Verify preview (5).

**Stacks.** A prompt can run on a whole stack (`PromptTarget`: the acted-on PR + its `StackEngine` stack bottom → top + a `wholeStack` flag). `A` on a stacked PR targets just that PR (**Tab** in the picker widens it to the whole stack); a stacked row's menu offers "Run Prompt on Stack (N)" and "Run Prompt on This PR", and the expanded stack header's menu offers the stack. **Hovering a stack header or any section/role header and pressing `A` runs on that whole group** (tracked in the reference-type `HoveredGroupBox`, cleared on hover-exit, `onDisappear` and popover dismiss; section headers' menus also offer "Run Prompt on <section> (N)"). A section is `PromptTarget.isGroup` — arbitrary PRs, not a merge-ordered stack — so it gets "This covers N PRs" wording and no `stacked` token; the session still runs in the FIRST PR's repo. `{{pr.*}}` is then the stack's BASE PR (the repo/branch/checkout the session uses); `{{stack.size|prs|urls|branches}}` list every PR (defined for a single PR too, size 1), and a template that mentions no `{{stack.*}}` gets the stack list appended. A state token holds for a stack when ANY member has it — except the branch-fixing ones (`conflict`, `ci-failing`, `changes-requested`, `unresolved-threads`), which only the BASE PR counts, since the session works on the base's branch (`PromptState.branchStateTokens`; Tab to a single PR to fix a later member) — and `stacked` holds when the target is a whole stack (so narrowing to one PR with Tab brings "Review PR" back on top). Row menus take the stack's members from the call site (never a per-row `stackIndex` read — it rebuilds every stack per access), and `DeckRowKey.stackMembers` carries them so a change to ANY member re-renders a memoized row; the quote guard covers every placeholder, `{{stack.*}}` included.

**`{{prompt}}` is mandatory** in every harness `command`/`url` — `PromptEngine.validate` rejects the harness otherwise (toast + warning in Settings), and a `repoUrls` override that drops it is caught separately (`PromptConfig.brokenRepoUrls` → Settings warning; `PromptLauncher.run` throws `PromptError.repoUrlMissingPrompt` only when that entry is the one that wins for the repo), so the user controls exactly how the prompt is passed. In a `url` it is percent-encoded (RFC 3986 unreserved only); in a `command` it expands to `"$(cat '<promptfile>')"` — the prompt text is written to a temp file, never spliced into the script, and `{{pr.*}}` values are single-quote-escaped (PR titles are attacker-controlled). Substitution is ONE pass, so a value containing `{{prompt}}` stays inert. CLI harnesses run via a generated `#!/bin/zsh -il` `.command` script (login shell → the user's PATH) in `NSTemporaryDirectory()/mainline-prompts` (pruned after a day); `settings.promptTerminal` (Auto = the system's `.command` handler, or Terminal / iTerm / Ghostty / Warp) picks the app. The picker's typed text becomes a free prompt prefixed with the PR URL + title (no template, no checkout). `runPrompt` is a NEW shortcut: when absent from stored bindings and its default `a` is already taken, it decodes as unbound rather than clashing.

### Comment templates (comment-triggered agent runs)

Right-click a PR → **Comment ▸ <template>** (or press `W`, `addComment`) posts a canned comment on the PR, which is how a repo's comment-triggered automation (an agent run, a bot command) is started. Files in `~/.config/mainline/comments/*.md`: frontmatter (`name`, `scope`, `when`, `priority`) + body with `{{pr.*}}` placeholders. **Scope is the point:** `scope:` is `owner/repo`, `owner/*` or `*` (comma-separated, case-insensitive; empty = every repo), so each org keeps its own set — `CommentEngine.appliesTo` filters the picker and the menu to the PR's `repoFullName`. No starter comments are seeded (what a comment triggers is org-specific; a wrong default would post somewhere it shouldn't).

It is a **GitHub write**: gated by `settings.writeActionsEnabled` (the `W` key shows the write-actions-disabled alert; the menu is disabled), posted by `PRManager.postComment` → `GitHubClient.addComment` (GraphQL `addComment`, subject = the PR's node id) → telemetry `recordWriteAction("comment")` → toast. It is NOT a `WriteAction` case and does not go through `performAction`/`dispatchVerb`. Confirmation: in the picker, choosing a row and pressing ↵ (or double-clicking) is the confirmation, and the picker previews the full rendered text first; the right-click submenu shows an NSAlert with the rendered text (`TriageDeckView.confirmAndPostComment`). Comments always target ONE PR — never a stack or section — because a fan-out would post on many PRs at once. Typed text is posted literally (never run through the placeholder engine). Posted comment text is never sent to telemetry. A new `addComment` shortcut decodes as unbound when its default `w` is already taken (same rule as `runPrompt`).

### Preview deployment detection
Each PR can carry a `vercelPreviewUrl` extracted from a PR issue comment (REST `GitHubClient.fetchPreviewURL`, pure `extractPreviewURL(from:domains:linkLabels:)`). The row shows a `PreviewBadge` when present, and `E` (deck or peek, default binding — user-configurable) opens it via `TriageDeckView.openPreview` (silent no-op when absent). Enrichment is **lazy + cached** in `PRPoller.enrichVercelPreviews`: the URL is keyed on `PRSnapshot.vercelPreviewCheckedAt` (the `updatedAt` it was checked at), carried forward while `updatedAt` is unchanged, and re-fetched only when a new commit bumps `updatedAt` — so a steady poll makes ~zero extra REST calls. Applied via `PRStateStore.applyVercelPreviews` (patches + persists, never re-diffs — a preview is not a notifiable transition). A pinned PR that has dropped out of the live queries never reaches this pass (it lives in `PRManager.pinnedFetchedPRs`, not `PRStateStore`), so it is enriched by the parallel `PRManager.pinnedPreviewEnriched(_:token:)` at fetch time — same gate, same carry-forward key — keeping the two paths' preview behavior identical.

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
| `collapsedSectionsRaw` | [String] | [] — `ActionGroup` rawValues for collapsed sections, plus `"inbox:<role>:<group>"` (per-role Inbox sections) and `"stack:<id>"` (a collapsed stack card, id = bottom PR nodeId) keys; the non-`ActionGroup` keys are ignored by the typed `collapsedSections` accessor |
| `snoozeMapData` | Data (JSON) | {} |
| `attentionPolicy` | [String: String] (`PREvent.rawValue` → `AttentionLevel.rawValue`) | `{}` — an ABSENT key falls back to `PREvent.defaults`, where `reviewRequested` and `reviewRequestedTeam` are `.notify` / `.quiet` respectively |
| `attentionPolicyMigrationVersion` | Int | `0` (absent) — last-applied `PREvent.policyMigrationVersion`; v1 clears a persisted `reviewRequested: quiet`; v2 copies `newReviewOrComment` → `newCommentOnReviewPR`. Rules are gated on the stored version so a bump never re-runs an older rule |
| `panelHeight` | Int | 1600 |
| `panelMinHeight` | Int | 600 |
| `panelBackgroundOpacity` | Double | `0` — how solid the popover background is. `0` = the stock system material (translucent / "liquid glass", unchanged); `1` = an opaque `windowBackgroundColor` fill like a native menu. `MenuBarView.panelBackdrop` paints it OVER the material and UNDER the content, skipping the layer entirely at `0`. Clamped through the pure `PanelBackdrop.clamped` on load AND in the `didSet` AND at the view's read site. Slider in Settings → Appearance → Panel. |
| `menuBarMetric` | String | `totalOpen` |
| `globalShortcutEnabled` | Bool | true |
| `globalShortcutKeyCode` | Int | `0x0A` (ISO section key) |
| `globalShortcutModifiers` | UInt | ⇧⌃ |
| `launchAtLogin` | Bool | false |
| `vercelPreviewEnabled` | Bool | true |
| `vercelPreviewDomains` | [String] | `["dash0-preview.com","vercel.app"]` |
| `previewCommentAuthors` | [String] | `["vercel[bot]","github-actions[bot]"]` — empty = scan every author |
| `previewLinkLabels` | [String] | `["preview"]` — case-insensitive substring match on a markdown link label |
| `promptTerminal` | String (`PromptTerminal` rawValue) | `auto` — terminal CLI prompt-template harnesses open in |
| `telemetryEnabled` | Bool | false |
| `shortcutBindings` | Data (JSON) | `InAppShortcutBindings.defaults` — 19 `ShortcutBinding { key, modifiers }` entries; all bare except undo=⌘Z (`modifiers = NSEvent.ModifierFlags.command.rawValue`). Includes `runPrompt` (default `a`, bare — opens the prompt-template picker), `addComment` (default `w`, bare — opens the comment picker, write-gated), `markReady` (default `t`, bare — draft→ready write action; **moved off `f`**), `copyBranch` (default `c`, bare), `togglePin` (default `p`, bare — pin/unpin), and `search` (default `f`, bare — open search). Decoded with custom `Codable` that handles both the new object shape and the v1.25.0 legacy bare-string shape; undo bare-string → `.command` migration preserves ⌘Z; on the upgrade that introduces `search` (its key absent in stored JSON), a `markReady` still bound to bare `f` is relocated to `t` so `f` is free for search; absent fields fall back to factory defaults. |
| `pinnedNodeIds` | [String] | `[]` — nodeIds the user has pinned. A pinned PR appears in a dedicated **Pinned** subsection at the top of its role/tab group (a `.pinned` display-only `ActionGroup`, collapsible, expanded by default) with a pin glyph, and overrides mute and the Drafts toggle (but not snooze, and not the org chip unless `pinsIgnoreOrgFilter` is on), and is fetched on demand (`node(id:)`) when it has dropped out of the live queries. Membership read via `settings.pinnedNodeIds`; toggled by the `togglePin` shortcut / context menu. |
| `unpinOnMerge` | Bool | `true` — when on, a PR auto-unpins once it has MERGED (not merely closed). Enforced by `PRManager.applyUnpinOnMerge`, run from the Done-set sink, the live-`prs` sink, and the on-demand pin fetch. Toggle in Settings → Appearance → Pinning. |
| `pinsIgnoreOrgFilter` | Bool | `false` — when OFF (default) pins are ORG-SCOPED: the Pinned subsection follows the org chip like every other section, so selecting `mthines` hides a pinned `dash0hq` PR. When ON, a pin overrides the chip and shows under every org (the pre-1.72 behaviour). Enforced by the single `PRManager.survivesScope(_:scope:)` predicate shared by `applyingSelectedScope` and `tabFiltered`. Scope only — mute, Drafts, snooze, search and the on-demand pin fetch are unaffected. Toggle in Settings → Appearance → Pinning. |
| `issueRepoWatchLevels` | Data (JSON `[String: String]`) | `{}` — per-repo `IssueWatchLevel` override |
| `issueOrgWatchLevels` | Data (JSON `[String: String]`) | `{}` — per-org default; repo override wins, fallback Only mine |
| `showNewIssuesInInbox` | Bool | true — "Show new issues in Inbox": up to 3 new-issue rows in the Inbox, the rest as "new issues → Issues tab" |
| `mutedIssueIds` | [String] | `[]` |
| `unreadIssueIds` | [String] | `[]` — one unread set serves the Issues tab and the Inbox group |
| `mutePatterns` | [String] | `["chore(deps)*", "build(deps)*"]` |
| `muteBotAuthors` | Bool | true |
| `botAllowList` | [String] | `[]` |
| `reviewFocusByOrg` | Data (JSON `[String: OrgFocusConfig]`) | `{}` |
| `muteLabels` | [String] | `[]` |
| `reviewNotReadyOnConflict` | Bool | true |
| `reviewNotReadyOnFailingCI` | Bool | true |
| `reviewNotReadyOnUnresolvedThreads` | Bool | true |
| `reviewNotReadyOnMyApproval` | Bool | true |
| `committedPRPlacement` | String (`CommittedPRPlacement` rawValue) | `yourPRs` |
| `committedPRBotAuthors` | [String] | `[]` — bots that open PRs for you; non-empty adds one committed-PR fetch per poll (1–5 paged light searches + one `nodes(ids:)` request) |

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
