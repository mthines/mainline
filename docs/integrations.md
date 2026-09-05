# Integrations

Mainline connects to two tools beyond GitHub: preview deployments and Linear.
Both work from the PR data alone — neither needs an extra API key.

## Preview links

Many teams deploy a preview of each PR — through Vercel's GitHub app, or through a
deploy workflow they wrote themselves.
Mainline finds that preview URL and puts it one keystroke away, either way.

### How it works

Mainline reads the PR's comments, keeps the ones written by a configured author, and
pulls the preview URL out of them.
When a PR has a preview, the row shows a **Preview** badge.
Press `E` — in the deck or in the peek card — to open it. (`E` is the default;
rebind it in **Settings → Keyboard**.)
On a PR without a preview, `E` does nothing.

The URL is found in three passes, so a comment doesn't have to look like Vercel's:

1. A markdown link whose label contains one of your **preview link labels** and whose
   host is one of your **preview domains**. This catches Vercel's own
   `[Visit Preview](…)` cell and a hand-written `[Preview](…)` cell alike.
2. A labelled link on any other host. This is what makes a preview on your own domain
   work without configuring anything. Links to `github.com`, `vercel.com` and
   `vercel.live` are ignored here — those sit *next to* a preview (the workflow run,
   the dashboard, the feedback widget), they are never the preview itself.
3. A bare URL anywhere in the comment that matches one of your preview domains.

Image links like `![Ready](…/ready.svg)` are skipped, so a status icon is never
mistaken for the preview. A badge that *is* a link — `[![Preview](badge.svg)](https://…)`,
a common shape in hand-rolled comments — still counts: the link it points at is used,
with the badge's alt text as the label. Domains are matched against the URL's host,
not the raw text, so `github.com/acme/tree/vercel.app` won't pass as a `vercel.app`
preview.

Detection is lazy and cached.
Mainline keys the URL to the commit it was checked at and reuses it until a new commit lands, so a steady poll makes almost no extra requests.

### Configure

Set these in **Settings → GitHub → Preview Deployments**.

- **Detect preview deployments** — on by default. Turning it off stops the extra per-PR comment fetches.
- **Comment authors** — whose comments get scanned. Defaults to `vercel[bot]` and
  `github-actions[bot]`, which together cover Vercel's app and any preview you deploy
  from GitHub Actions with the default token. If your preview is posted by a custom
  GitHub App, add its login — or clear the field to scan every author.
- **Preview link labels** — matched case-insensitively against a link's label.
  Default `preview`, which already covers `[Preview](…)`, `[Visit Preview](…)` and
  `[Open preview → …](…)`.
- **Preview domains** — an ordered list of host suffixes, most-preferred first.
  Default `dash0-preview.com`, then `vercel.app`. Add your own custom preview domains here.

Labels and domains are independent: clearing both switches detection off, but either
one on its own still finds previews.

**Not seeing a preview that exists?** Open the PR comment that carries it and check two
things: who posted it (add that login to **Comment authors**) and how the URL is
written (if it isn't a link labelled "preview", add its host to **Preview domains** or
its label to **Preview link labels**).

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
