# Mainline documentation

Mainline is a macOS menu bar app that keeps you on top of your GitHub pull requests.
This directory holds the full guide.
For install and a one-screen overview, start with the [project README](../README.md).

## Using Mainline

Read these in order the first time.
After that, treat them as reference.

- [Getting started](./getting-started.md) — connect a GitHub token and take your first look.
- [The panel](./the-panel.md) — tabs, actionability groups, drafts, scope, and the menu bar badge.
- [Notifications](./notifications.md) — the four events, per-event attention levels, and noise control.
- [Keyboard triage](./keyboard.md) — every key, the peek card, the row menu, and the global shortcut.
- [Filtering the Inbox](./filtering.md) — the four mute rules and the review-focus allow-list.
- [Write actions](./actions.md) — approve, merge, and request changes from the menu bar.
- [Integrations](./integrations.md) — Vercel preview links and opening PRs in Linear.

## Reference

- [Settings](./settings.md) — every setting, grouped by pane, with its default.

## Under the hood

For contributors and operators.

- [Architecture](./architecture.md) — how the app is built and where state lives.
- [Release pipeline](./release.md) — the CI release model, secrets, and signing.
- [Telemetry](./telemetry.md) — the opt-in, anonymous observability contract.

## Conventions in these docs

- A **PR** is a GitHub pull request.
- The **panel** is the window that opens when you click the menu bar icon.
- The **deck** is the keyboard-driven list of PRs inside the panel.
- A **verb** is a single triage action, such as merge or snooze.
