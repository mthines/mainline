# Observability Profile

> Written by `measurable` `setup` mode. Committed via
> `persistent-memory` (`project-shared` tier). Re-run `/measurable setup` to update.

Last updated: 2026-11-25

## Package Map

| Path glob | Kind | Telemetry stack | RUM/analytics stack | Defers to skill (if any) |
| --- | --- | --- | --- | --- |
| `Mainline/**` | `api` (native macOS menu-bar app; no web/mobile kind fits) | OpenTelemetry Swift SDK 1.17.1 → OTLP/HTTP → Dash0 (opt-in, default OFF, via `TelemetryService.shared`) | none — product analytics are OTel counters (e.g. `mainline.triage_interactions`) | `otel-instrumentation` / `otel-semantic-conventions` when installed |

## Telemetry Schema

- Registry: none
- Upstream semconv dependency: —
- Weaver version: —
- CI gate: none

## Interaction Capture

- Mechanism: none
- Context attribute: —
- Mounted in: —
- Customer-data opt-out: —
- Test-id catalog: none

## Regression Detection Surface

- Existing dashboards: none yet
- Existing check rules: none yet
- Status: propose-via-dash0-chat pending

## Notes

- Privacy rule: never pass PR titles, repo names, branch names, user logins, or tokens to `TelemetryService`. Full guide: `docs/telemetry.md`.
- Every new signal needs a bounded-parameter method on `TelemetryService` plus its instrument in `setupOTel()`.
- Key regression signals: `mainline.poll.errors`, `mainline.poll.duration`, and `mainline.poll.carried_forward`. If `carried_forward` falls to zero while `poll.degraded="true"` keeps arriving, the baseline guard is broken.
