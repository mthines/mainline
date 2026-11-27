# Agents: prompts and comments

Mainline can hand a PR to an AI agent, or ping the automation your repo already has, without you leaving the menu bar.
There are two tools, both driven by plain Markdown files you own:

- **Prompt templates** start an agent session (Claude Code in a terminal, or Agent0 in the browser) about a PR.
- **Comment templates** post a canned comment on a PR, which starts whatever your repo runs on that comment, such as an agent run or a bot command.

Both open the same kind of picker: type to filter, ↑/↓ to choose, ↵ to go.

## Prompt templates

Press `A` on a PR, or right-click → **Run Prompt**.
Mainline fills a template with the PR's facts and starts the session for you.

- **Where they live:** `~/.config/mainline/prompts/*.md`; hooks are in `~/.config/mainline/hooks/*.md`. One file per template, with a short header and the prompt as the body.
- **Starters:** Resolve merge conflicts, Fix failing CI, Address review feedback, Review PR, Analyse telemetry and Verify preview.
- **Suggested first:** a template's `when:` line (for example `authored+ci-failing`) floats it to the top when the PR is in that state, marked with a star.
- **Placeholders:** `{{pr.url}}`, `{{pr.number}}`, `{{pr.title}}`, `{{pr.repo}}`, `{{pr.owner}}`, `{{pr.branch}}`, `{{pr.base}}` and `{{pr.author}}`.
- **Harnesses:** a template names the tool that runs it. Several can be listed, and ←/→ in the picker switches between them. Harness commands, repo paths and the checkout step live in `~/.config/mainline/config.json`.
- **Stacks and sections:** run a prompt on a whole stack, or hover a section header and press `A` to run it on every PR in the group.
- **Free text:** type something that matches no template and Mainline asks your default harness about that PR directly.

See [Settings → Prompts](./settings.md#prompts) for the full list of options.

## Hooks

A prompt template with an `on:` line also runs by itself when a PR changes state, for example `on: ci-failed, approved`.
- **Triggers:** approved, changes-requested, ci-failed, ci-passed, conflict, ready-to-merge, new-comment, review-requested, ready-for-review, merged, closed.
- **Scope:** `scope:` limits the hook to repos (`owner/repo`, `owner/*`, `*`). `role:` is `authored` (default, your own PRs), `reviewing` or `any`. `when:` adds a PR-state guard.
- **Your own comments and a run limit:** `new-comment` ignores comments and reviews you wrote yourself, so an agent that comments back as you cannot start itself again. `self: true` lets your own comments and reviews start the hook (bot comments stay ignored). `max-runs: N` starts the hook at most N times per PR or issue, counted across launches and kept in `~/.config/mainline/hook-runs.json` (a start you cancel does not count; raise or remove the number to start again). Settings warns about `self: true` without `max-runs` and suggests 3. A hook over its limit is recorded as `skipped` with reason `max_runs`.
- **Safety:** a notification with a Cancel button counts down before each launch (10s by default). Hooks are held when notifications are off, never fire for your own comments, and run at most once per PR and trigger every 30 minutes and 10 times an hour. A hook never runs the checkout step.
- **Editing hooks in Settings** (behind feature flag `hook-editor`, off by default; turn it on in Settings → Developer): each hook gets an on/off switch, a one-line sentence and **Edit…**, which opens a sheet for the triggers, which PRs, repos, an "only when" guard, harness, priority and the prompt. A switched-off hook writes `enabled: false`, keeps its settings and stays in the list; no `enabled:` line means on. Saving from Settings changes only the lines it edits, so your own `#` comments and extra keys stay in the file. **Open in Editor** is still in the sheet. A hook runs one prompt for every trigger you tick, and watches one `check:` name.
- **One named check** (behind feature flag `check-hooks`, off by default; turn it on in Settings → Developer): `on: check-failed` or `on: check-passed` plus `check: <name>` fires when that one GitHub Actions job (or commit status such as Vercel's) changes, instead of the whole CI rollup. `check:` holds one name, matched case-insensitively and exactly; `*` matches any run of characters (`build*`). The name goes in its own line because matrix names such as `build (ubuntu, 20)` contain commas. Failed means failure, timed out, startup failure or action required; cancelled and skipped do not count. The first poll after an upgrade, or a check beyond the first 50 on a PR, never fires; a check that fails again after a push does. `role:`, `scope:`, `when:`, the countdown and the throttle (per hook, check and PR) work as above. Settings → Prompts → Hooks warns about a check hook with no `check:`. Mainline only asks GitHub for per-check data while the flag is on and a check hook exists.
- **Issues** (behind feature flag `issue-hooks`, off by default; turn it on in Settings → Developer): add `for: issues` and the hook fires on issue changes instead of PR ones, with `{{issue.*}}` in its prompt. `for: both` fires on either, but only where its prompt can be filled: a `{{pr.*}}` prompt fires on PRs only, an `{{issue.*}}` prompt on issues only (Settings → Prompts → Hooks warns). Issue triggers: new-issue, assigned, mentioned, new-comment, closed. `role: authored` means you opened the issue; set `role: any` to fire on other people's issues (needed for new-issue, assigned and mentioned). `when:` is PR-only, so an issue hook with one never fires. A hook never fires on the first poll after launch, and muted issues fire nothing.

## Comment templates

Press `W` on a PR, or right-click → **Comment**.
Pick a canned comment and Mainline posts it on the PR.
Use it for things like `/aw-verify` or `/beta` that kick off a run, so you stop retyping them on every PR.

- **Where they live:** `~/.config/mainline/comments/*.md`.
- **Scoped per org or repo:** `scope:` takes `owner/repo`, `owner/*` or `*`, comma-separated. Leave it out to offer a comment everywhere. A PR only sees the comments that match its repo.
- **Preview first:** the picker shows the full text before you post. The right-click menu asks first.
- **One PR at a time:** a comment is never posted on a whole stack or section.
- **Needs write actions:** turn on **Enable write actions** in Settings → GitHub.

```
---
name: Beta release
scope: acme/*
---
/beta
```

See [Settings → Comments](./settings.md#comments) for `when:`, `priority:` and the placeholders.

## Set up your own

1. Open **Settings → Prompts** or **Settings → Comments** and click **New**, or drop a `.md` file into the folder.
2. Edits made in an editor are picked up within a couple of seconds.
3. Rebind the keys in **Settings → Keyboard** if `A` or `W` clash with your habits.
