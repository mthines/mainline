# Mainline Telemetry

Anonymous, opt-in observability for the Mainline macOS menu-bar app. Signals
are exported via OTLP/HTTP to Dash0 using opentelemetry-swift 1.17.1.

## Opt-in model

Telemetry is **disabled by default**. The user must explicitly enable it
through one of two paths:

1. **Banner** — shown once at the top of Settings → Privacy when
   `telemetryBannerDismissed` is false. Tapping "Enable" sets
   `MainlineSettings.telemetryEnabled = true`.
2. **Toggle** — the "Share anonymous usage data" toggle in Settings → Privacy.

Disabling the toggle stops new events from being recorded immediately
(all `TelemetryService` methods guard-return on `telemetryEnabled == false`).
In-flight spans are flushed at the next `applicationWillTerminate`.

## Architecture

```
MainlineSettings.telemetryEnabled (UserDefaults)
       │
       ├── true  → TelemetryService.shared.configure()
       │           Sets up trace/metric/log providers → OTLP/HTTP → Dash0
       │
       └── false → All TelemetryService methods are no-ops
```

**Single entry point:** `TelemetryService.shared` is a private-init singleton.
`configure()` is called from:
- `MainlineSettings.telemetryEnabled.didSet` (on enable)
- `AppDelegate.applicationDidFinishLaunching` in `MainlineApp.swift` (at launch, if already enabled)

`shutdown()` is called from `AppDelegate.applicationWillTerminate`.

## SDK notes

opentelemetry-swift 1.17.1 requires a **wildcard view registration** for the
stable metrics API — without it, all metric instruments silently record to
no-op storage:

```swift
StableMeterProviderSdk.builder()
    .registerView(
        selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
        view: StableView.builder().build()
    )
```

This is already in `TelemetryService.setupOTel()`. Do not remove it.

## Configuration

Credentials are embedded at build time via Info.plist and build settings:

| Info.plist key        | Build setting                  | Purpose                        |
| --------------------- | ------------------------------ | ------------------------------ |
| `Dash0AuthToken`      | `$(DASH0_AUTH_TOKEN)`          | Bearer token for Dash0 ingest  |
| `OTelExporterEndpoint`| `$(OTEL_EXPORTER_OTLP_ENDPOINT)` | OTLP/HTTP base URL           |
| `GitCommitSHA`        | injected by PlistBuddy shell phase | Service version suffix     |

Override priority (highest → lowest):
1. Process environment (`DASH0_AUTH_TOKEN`, `OTEL_EXPORTER_OTLP_ENDPOINT`)
2. `~/.config/mainline/.env` file (developer convenience)
3. Info.plist (embedded at build time)

If `DASH0_AUTH_TOKEN` is unset or empty, `setupOTel()` exits early —
telemetry silently does nothing (correct for dev builds without the token).

## Signals

### Traces

| Span name          | When started              | Key attributes                                           |
| ------------------ | ------------------------- | -------------------------------------------------------- |
| `mainline session` | On `configure()`          | `session.app_version`                                    |
| `mainline poll`    | `recordPollStarted()`     | `poll.query_type`, `poll.result`, `poll.result_count`, `poll.duration_s` |

### Metrics

| Metric name                        | Type      | Attributes                                               |
| ---------------------------------- | --------- | -------------------------------------------------------- |
| `mainline.app.launch`              | counter   | —                                                        |
| `mainline.poll.duration`           | histogram | `poll.query_type`, `poll.result`                         |
| `mainline.poll.etag_hits`          | counter   | `poll.query_type`                                        |
| `mainline.poll.errors`             | counter   | `poll.query_type`, `error.type`                          |
| `mainline.write_actions`           | counter   | `write.action`, `write.result`, `write.merge_method`     |
| `mainline.triage_interactions`     | counter   | `interaction.type`                                       |
| `mainline.notifications.fired`     | counter   | `notification.event_type`, `notification.attention_level`|
| `mainline.notifications.suppressed`| counter   | —                                                        |
| `mainline.global_shortcut.used`    | counter   | —                                                        |
| `mainline.token.invalid`           | counter   | —                                                        |
| `mainline.setting.changed`         | counter   | `setting.name`, `setting.enabled`                        |
| `mainline.attention_policy.changed`| counter   | `attention.event`, `attention.level`                     |

### Logs

Structured log records for key lifecycle events:

| Body                 | Severity | Attributes                                        |
| -------------------- | -------- | ------------------------------------------------- |
| `App launched`       | INFO     | `app.version`                                     |
| `App upgraded`       | INFO     | `deployment.from_version`, `deployment.to_version`|
| `Session ended`      | INFO     | `session.duration_s`                              |
| `Session heartbeat`  | INFO     | — (fires every 5 minutes)                         |
| `Write action …`     | INFO/WARN| `write.action`, `write.result`, `write.duration_s`|
| `Token imported`     | INFO     | `token.import_method`                             |
| `Token invalid`      | WARN     | —                                                 |
| `Setting changed`    | INFO     | `setting.name`, `setting.enabled`                 |
| `Attention policy changed` | INFO | `attention.event`, `attention.level`            |

### Resource attributes (on every signal)

| Attribute                        | Value                                        |
| -------------------------------- | -------------------------------------------- |
| `service.name`                   | `"mainline"`                                 |
| `service.namespace`              | `"mainline"`                                 |
| `service.version`                | bundle short version + build + git SHA       |
| `service.instance.id`            | random UUID per install (from UserDefaults)  |
| `enduser.id`                     | HMAC-SHA256 of hardware UUID (non-reversible)|
| `os.type`                        | `"darwin"`                                   |
| `os.version`                     | `ProcessInfo.operatingSystemVersionString`   |
| `deployment.environment.name`    | `"development"` (DEBUG) / `"production"`     |

## Bounded attribute values

All attributes use **bounded, low-cardinality values** — never raw user data.

| Attribute            | Allowed values                                                                                   |
| -------------------- | ------------------------------------------------------------------------------------------------ |
| `poll.query_type`    | `"author"`, `"reviewer"` (derived from query string identity, not content)                       |
| `poll.result`        | `"success"`, `"etag_304"`, `"failure"`, `"abandoned"`, `"app_shutdown"`                          |
| `error.type`         | `"unauthorized"`, `"rate_limited"`, `"server_error"`, `"cancelled"`, `"decoding"`, `"network_error"`, `"action_failed"`, `"not_modified"`, `"unknown"` |
| `write.action`       | `"approve"`, `"merge"`, `"request_changes"`                                                      |
| `write.result`       | `"success"`, `"failure"`                                                                         |
| `write.merge_method` | `"squash"`, `"merge"`, `"rebase"`, `"auto"` (from resolved preference, never PR title/branch)   |
| `interaction.type`   | `"snooze"`, `"unsnooze"`, `"mark_seen"`, `"dismiss"`, `"open_in_browser"`, `"diff_preview"`, `"open_preview"`, `"tab_switch"`, `"scope_filter_change"`, `"toggle_drafts"`, `"inbox_mute"`, `"inbox_unmute"`, `"undo"`, `"refresh"`, `"multi_select_toggle"` |
| `notification.event_type` | `"newPR"`, `"readyForReview"`, `"ciChanged"`, `"reviewComment"`                           |
| `notification.attention_level` | `"notify"`, `"quiet"`                                                                |
| `attention.event`    | `PREvent` raw values (e.g. `"reviewRequested"`, `"ciFailedOnMyPR"`) — never PR content |
| `attention.level`    | `"notify"`, `"quiet"`, `"off"`                                                                   |
| `token.import_method`| `"gh"`, `"paste"`                                                                                |
| `setting.name`       | UserDefaults key names (never values) — `"writeActionsEnabled"`, `"vercelPreviewEnabled"`, `"notifyOnlyHumanComments"`, `"menuBarScopeFollowsSelection"`, `"globalShortcutEnabled"`, `"compactRows"`, `"splitDrafts"`, `"muteBotAuthors"` |

## Privacy contract

**NEVER include in any telemetry attribute:**
- PR titles, PR descriptions, PR numbers
- Repository names, organisation names, branch names
- Author usernames, reviewer usernames, any GitHub login
- GitHub tokens or credentials
- Raw error messages (use error *categories* only)
- IP addresses or network identifiers

This is enforced by:
1. `TelemetryService` methods accept only typed/bounded parameters (no PR model objects).
2. `categorizeGitHubError(_ error: GitHubAPIError)` maps typed errors to category strings.
3. AC-34 grep check: `grep -n '\.title\|\.nodeId\|repoFullName\|\.author\|\.headRefName' TelemetryService.swift` must return empty.

## How to add instrumentation

1. Identify the signal type: trace span, metric counter/histogram, or log.
2. Add a method to `TelemetryService` following the existing pattern:
   - Guard on `MainlineSettings.shared.telemetryEnabled` at the top.
   - Call `ensureSetup()`.
   - Use only bounded attribute values — no PR model fields.
3. Add the instrument (`counterBuilder`, `histogramBuilder`) to `setupOTel()` and declare the property.
4. Call the new method from the instrumented site.
5. Add the new metric/span/log to the tables above.
6. Verify the privacy contract (step 3 of Privacy contract above).

## SPM dependency

```
https://github.com/open-telemetry/opentelemetry-swift
exact: 1.17.1
products: OpenTelemetryApi, OpenTelemetrySdk, OpenTelemetryProtocolExporterHTTP
```

Wired into `Mainline.xcodeproj/project.pbxproj` using `OT000…`-prefixed IDs.
