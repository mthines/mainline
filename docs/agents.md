# Agents: prompts and comments

Mainline can hand a PR to an AI agent, or ping the automation your repo already has, without you leaving the menu bar.
There are two tools, both driven by plain Markdown files you own:

- **Prompt templates** start an agent session (Claude Code in a terminal, or Agent0 in the browser) about a PR.
- **Comment templates** post a canned comment on a PR, which starts whatever your repo runs on that comment, such as an agent run or a bot command.

Both open the same kind of picker: type to filter, ↑/↓ to choose, ↵ to go.

## Prompt templates

Press `A` on a PR, or right-click → **Run Prompt**.
Mainline fills a template with the PR's facts and starts the session for you.

- **Where they live:** `~/.config/mainline/prompts/*.md`. One file per template, with a short header and the prompt as the body.
- **Starters:** Resolve merge conflicts, Fix failing CI, Address review feedback, Review PR, Analyse telemetry and Verify preview.
- **Suggested first:** a template's `when:` line (for example `authored+ci-failing`) floats it to the top when the PR is in that state, marked with a star.
- **Placeholders:** `{{pr.url}}`, `{{pr.number}}`, `{{pr.title}}`, `{{pr.repo}}`, `{{pr.owner}}`, `{{pr.branch}}`, `{{pr.base}}` and `{{pr.author}}`.
- **Harnesses:** a template names the tool that runs it. Several can be listed, and ←/→ in the picker switches between them. Harness commands, repo paths and the checkout step live in `~/.config/mainline/config.json`.
- **Stacks and sections:** run a prompt on a whole stack, or hover a section header and press `A` to run it on every PR in the group.
- **Free text:** type something that matches no template and Mainline asks your default harness about that PR directly.

See [Settings → Prompts](./settings.md#prompts) for the full list of options.

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
