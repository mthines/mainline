# Integrations

Mainline connects to two tools beyond GitHub: Vercel preview deployments and Linear.
Both work from the PR data alone — neither needs an extra API key.

## Vercel preview links

Many teams deploy a preview of each PR through Vercel.
Mainline finds that preview URL and puts it one keystroke away.

### How it works

Mainline reads the PR's `vercel[bot]` comment and extracts the preview URL.
When a PR has a preview, the row shows a **Preview** badge.
Press `E` — in the deck or in the peek card — to open it.
On a PR without a preview, `E` does nothing.

Detection is lazy and cached.
Mainline keys the URL to the commit it was checked at and reuses it until a new commit lands, so a steady poll makes almost no extra requests.

### Configure

Set both options in **Settings**.

- **Vercel preview detection** — on by default. Turning it off stops the extra per-PR comment fetches.
- **Preview domains** — an ordered list of host suffixes the URL must match, most-preferred first. Default `dash0-preview.com`, then `vercel.app`. Add your own custom preview domains here.

## Open PRs in Linear

By default the "open" action sends you to the GitHub PR page.
You can send it to the PR's review view in Linear instead — useful when your team reviews inside Linear.

### How it works

Set the open target to Linear in **Settings**.
When Linear applies, opening a PR builds a `linear://` deep link to the review view and hands off to the Linear desktop app.

Mainline derives the link from the PR URL alone — no API key and no workspace slug.
Your Linear session supplies the workspace.

The fallbacks, in order:

1. The `linear://` deep link opens the Linear desktop app.
2. If the desktop app isn't installed, a `linear.review` web link opens the review page in the browser.
3. If the URL isn't a GitHub PR, it falls back to the GitHub page.

The peek card's Safari button always opens GitHub, whatever the open target.

### Choose which repos use Linear

The **Linear repo filter** decides which repos open in Linear.

- **Empty (default)** — every repo opens in Linear.
- **Non-empty** — an allow-list. Only matching repos open in Linear; the rest stay on GitHub.

Each entry is either an organization (`owner`, matching every repo under it) or an exact repo (`owner/repo`).
Matching is case-insensitive.
This lets work repos open in Linear while personal repos stay on GitHub.
