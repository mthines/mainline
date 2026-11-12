import Foundation

// MARK: - Models

/// One prompt template: a Markdown file in `~/.config/mainline/prompts/`.
///
///     ---
///     name: Review PR
///     harness: claude
///     checkout: true
///     ---
///     Review {{pr.url}} …
struct PromptTemplate: Identifiable, Equatable {
    /// File name inside the prompts folder (`review-pr.md`) — the stable identity.
    var fileName: String
    var name: String
    /// Key into `PromptConfig.harnesses`.
    var harness: String
    /// Run `PromptConfig.checkout` in the repo's local path before the harness starts.
    var checkout: Bool
    var body: String

    var id: String { fileName }
}

/// A harness is either a CLI command run in a terminal (`command`) or a web page
/// opened in the browser (`url`). Both MUST contain `{{prompt}}` — that is where the
/// rendered template text is inserted, so the user controls exactly how it is passed.
struct HarnessConfig: Codable, Equatable {
    var label: String
    var command: String?
    var url: String?
    /// `false` hides the harness everywhere and refuses to run it. Absent = enabled.
    var enabled: Bool?

    var isEnabled: Bool { enabled != false }
    var isWeb: Bool { url != nil }
    /// The string the `{{prompt}}` placeholder lives in.
    var target: String { url ?? command ?? "" }
}

/// `~/.config/mainline/config.json`.
struct PromptConfig: Codable, Equatable {
    /// Pre-step run before a CLI harness when the template sets `checkout: true`.
    /// Placeholders: any `{{pr.*}}`.
    var checkout: String
    /// `owner/repo` → local clone path (`~` allowed). Harnesses start here.
    var repos: [String: String]
    var harnesses: [String: HarnessConfig]
    /// Harness keys in priority order, first = default. Harnesses not listed come after,
    /// sorted by label.
    var order: [String]

    enum CodingKeys: String, CodingKey { case checkout, repos, harnesses, order }

    init(checkout: String, repos: [String: String], harnesses: [String: HarnessConfig], order: [String] = []) {
        self.checkout = checkout
        self.repos = repos
        self.harnesses = harnesses
        self.order = order
    }

    /// Lenient: a hand-edited file that omits a section keeps that section's default
    /// instead of being rejected whole (which would silently leave the defaults active).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PromptConfig.default
        checkout = try c.decodeIfPresent(String.self, forKey: .checkout) ?? d.checkout
        repos = try c.decodeIfPresent([String: String].self, forKey: .repos) ?? [:]
        harnesses = try c.decodeIfPresent([String: HarnessConfig].self, forKey: .harnesses) ?? d.harnesses
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? d.order
    }

    static let `default` = PromptConfig(
        checkout: "gh pr checkout {{pr.number}}",
        repos: [:],
        harnesses: [
            "claude":   HarnessConfig(label: "Claude Code", command: "claude {{prompt}}", url: nil),
            "codex":    HarnessConfig(label: "Codex", command: "codex {{prompt}}", url: nil),
            "amp":      HarnessConfig(label: "Amp", command: "amp {{prompt}}", url: nil),
            "opencode": HarnessConfig(label: "opencode", command: "opencode --prompt {{prompt}}", url: nil),
            "agent0":   HarnessConfig(label: "Agent0 (web)", command: nil,
                                      url: "https://app.dash0.com/agent0?prompt={{prompt}}"),
        ],
        order: ["claude", "codex", "amp", "opencode", "agent0"]
    )

    /// ALL harnesses (enabled or not) in priority order: `order` first, then the rest by label.
    var orderedHarnesses: [(key: String, value: HarnessConfig)] {
        var rank: [String: Int] = [:]
        for (i, key) in order.enumerated() where rank[key] == nil { rank[key] = i }
        return harnesses.sorted { a, b in
            let ra = rank[a.key] ?? Int.max, rb = rank[b.key] ?? Int.max
            if ra != rb { return ra < rb }
            return a.value.label.localizedCaseInsensitiveCompare(b.value.label) == .orderedAscending
        }.map { (key: $0.key, value: $0.value) }
    }

    /// Enabled harnesses in priority order — what pickers offer; the first is the default.
    var enabledHarnesses: [(key: String, value: HarnessConfig)] {
        orderedHarnesses.filter { $0.value.isEnabled }
    }

    /// Moves a harness up (`-1`) or down (`+1`) in priority. Pure; no-op at the ends.
    func moving(_ key: String, by delta: Int) -> PromptConfig {
        var keys = orderedHarnesses.map(\.key)
        guard let i = keys.firstIndex(of: key), keys.indices.contains(i + delta) else { return self }
        keys.swapAt(i, i + delta)
        var copy = self
        copy.order = keys
        return copy
    }

    /// Enables or disables a harness (enabled is stored as an absent field). Pure.
    func settingEnabled(_ key: String, _ on: Bool) -> PromptConfig {
        var copy = self
        copy.harnesses[key]?.enabled = on ? nil : false
        return copy
    }

    /// Local path for a repo (case-insensitive `owner/repo` match), `~` expanded.
    func localPath(forRepo repo: String) -> String? {
        guard let raw = repos.first(where: { $0.key.caseInsensitiveCompare(repo) == .orderedSame })?.value,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (raw as NSString).expandingTildeInPath
    }
}

// MARK: - Context

/// The PR facts available to `{{pr.*}}` placeholders.
struct PromptContext: Equatable {
    var values: [String: String]

    init(values: [String: String]) { self.values = values }

    init(pr: PRSnapshot) {
        let owner = pr.repoFullName.split(separator: "/").first.map(String.init) ?? ""
        values = [
            "pr.url": pr.htmlUrl,
            "pr.number": String(pr.number),
            "pr.title": pr.title,
            "pr.repo": pr.repoFullName,
            "pr.owner": owner,
            "pr.branch": pr.headRefName,
            "pr.base": pr.baseRefName,
            "pr.author": pr.author,
        ]
    }

    static let placeholderNames = ["pr.url", "pr.number", "pr.title", "pr.repo",
                                   "pr.owner", "pr.branch", "pr.base", "pr.author"]
}

// MARK: - Engine (pure)

enum PromptError: Error, Equatable, LocalizedError {
    case missingPromptPlaceholder(harness: String)
    case unknownHarness(String)
    case unknownPlaceholder(String)
    case harnessHasNoTarget(String)
    case placeholderInQuotes(String)
    case harnessDisabled(String)

    var errorDescription: String? {
        switch self {
        case .missingPromptPlaceholder(let h):
            return "Harness “\(h)” must contain {{prompt}} in its command or url — that's where the prompt is inserted."
        case .unknownHarness(let h):
            return "Unknown harness “\(h)” — add it to config.json."
        case .unknownPlaceholder(let p):
            return "Unknown placeholder {{\(p)}}."
        case .harnessHasNoTarget(let h):
            return "Harness “\(h)” needs a `command` or a `url`."
        case .harnessDisabled(let h):
            return "Harness “\(h)” is disabled — turn it on in Settings → Prompts."
        case .placeholderInQuotes(let p):
            return "{{\(p)}} is inside quotes in a command — remove the quotes; Mainline already quotes it safely."
        }
    }
}

/// What the launcher should do.
enum PromptLaunch: Equatable {
    case web(URL)
    /// A zsh script for a terminal, plus the prompt text it reads from a file.
    case terminal(script: String, promptText: String)
}

enum PromptEngine {
    static let promptToken = "{{prompt}}"

    // MARK: Parse / serialize

    /// Parses a template file. Returns nil only when there is no usable name — a
    /// file without frontmatter is still a template, named after its file.
    static func parse(fileName: String, text: String) -> PromptTemplate? {
        var meta: [String: String] = [:]
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")

        if body.hasPrefix("---\n") {
            let rest = body.dropFirst(4)
            if let end = rest.range(of: "\n---") {
                let header = rest[rest.startIndex..<end.lowerBound]
                var after = rest[end.upperBound...]
                if after.hasPrefix("\n") { after = after.dropFirst() }
                body = String(after)
                for line in header.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("#") { continue }
                    guard let colon = trimmed.firstIndex(of: ":") else { continue }
                    let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    // Whole-line `#` comments only: a trailing ` #` would cut a name like
                    // "Fix #123 regressions" short.
                    meta[key] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        let fallbackName = (fileName as NSString).deletingPathExtension
        let name = (meta["name"]?.isEmpty == false ? meta["name"]! : fallbackName)
        guard !name.isEmpty else { return nil }
        let checkout = ["true", "yes", "1"].contains((meta["checkout"] ?? "").lowercased())
        return PromptTemplate(
            fileName: fileName,
            name: name,
            harness: meta["harness"] ?? "claude",
            checkout: checkout,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func serialize(_ t: PromptTemplate) -> String {
        """
        ---
        name: \(t.name)
        harness: \(t.harness)
        checkout: \(t.checkout ? "true" : "false")
        ---
        \(t.body)

        """
    }

    /// `Review PR!` → `review-pr.md`, de-duplicated against `existing`.
    static func fileName(forName name: String, existing: Set<String>) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let base = slug.isEmpty ? "template" : slug
        var candidate = "\(base).md"
        var n = 2
        while existing.contains(candidate) { candidate = "\(base)-\(n).md"; n += 1 }
        return candidate
    }

    // MARK: Validation

    /// Problems that would stop `template` from running; empty when it is fine.
    static func validate(_ template: PromptTemplate, config: PromptConfig) -> [PromptError] {
        var errors: [PromptError] = []
        errors.append(contentsOf: validate(harnessKey: template.harness, config: config))
        for name in placeholders(in: template.body) where !PromptContext.placeholderNames.contains(name) {
            errors.append(.unknownPlaceholder(name))
        }
        if template.checkout, let bad = quotedPlaceholders(in: config.checkout).first {
            errors.append(.placeholderInQuotes(bad))
        }
        return errors
    }

    static func validate(harnessKey: String, config: PromptConfig) -> [PromptError] {
        guard let harness = config.harnesses[harnessKey] else { return [.unknownHarness(harnessKey)] }
        if !harness.isEnabled { return [.harnessDisabled(harnessKey)] }
        if harness.target.isEmpty { return [.harnessHasNoTarget(harnessKey)] }
        if !harness.target.contains(promptToken) { return [.missingPromptPlaceholder(harness: harnessKey)] }
        if let command = harness.command, let bad = quotedPlaceholders(in: command).first {
            return [.placeholderInQuotes(bad)]
        }
        return []
    }

    /// Placeholders that sit inside shell quotes in `command`: any `{{pr.*}}` (its value
    /// is single-quoted on substitution, which only protects it OUTSIDE quotes — inside
    /// double quotes a PR title like `$(…)` would still run) and `{{prompt}}` inside
    /// single quotes (it expands to a double-quoted `"$(cat …)"`).
    static func quotedPlaceholders(in command: String) -> [String] {
        var found: [String] = []
        var quote: Character?
        var i = command.startIndex
        while i < command.endIndex {
            let c = command[i]
            if c == "\\" && quote != "'" {            // an escaped character is never a quote
                i = command.index(after: i)
                if i < command.endIndex { i = command.index(after: i) }
                continue
            }
            if quote == nil {
                if c == "'" || c == "\"" { quote = c }
            } else if c == quote {
                quote = nil
            } else if c == "{", command[i...].hasPrefix("{{"),
                      let close = command.range(of: "}}", range: i..<command.endIndex) {
                let name = command[command.index(i, offsetBy: 2)..<close.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("pr.") || (name == "prompt" && quote == "'") { found.append(name) }
                i = close.upperBound
                continue
            }
            i = command.index(after: i)
        }
        return found
    }

    /// Names inside `{{…}}`, in order.
    static func placeholders(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            out.append(rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces))
            rest = rest[close.upperBound...]
        }
        return out
    }

    // MARK: Rendering

    /// Replaces every `{{pr.*}}` in `text` via `transform` and `{{prompt}}` with `prompt`
    /// (left as the literal token when nil), in ONE pass — substituted values are never
    /// re-scanned, so a PR title containing `{{prompt}}` stays inert text.
    /// Throws on an unknown placeholder.
    static func substitute(_ text: String, context: PromptContext, prompt: String? = nil,
                           transform: (String) -> String = { $0 }) throws -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else { break }
            result += rest[rest.startIndex..<open.lowerBound]
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if name == "prompt" {
                result += prompt ?? promptToken
            } else if let value = context.values[name] {
                result += transform(value)
            } else {
                throw PromptError.unknownPlaceholder(name)
            }
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    /// The prompt text a template produces for a PR.
    static func renderBody(_ template: PromptTemplate, context: PromptContext) throws -> String {
        // `{{prompt}}` in a body would recurse into itself — it is reserved.
        if placeholders(in: template.body).contains("prompt") { throw PromptError.unknownPlaceholder("prompt") }
        return try substitute(template.body, context: context)
    }

    /// Single-quote a value for zsh.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// RFC 3986 unreserved characters only, so `&`, `=`, `#`, `+` and `?` in a
    /// prompt can't break out of the query value.
    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Builds the launch for an already-rendered prompt.
    /// - Parameters:
    ///   - promptFile: where the launcher will write `prompt` so a CLI harness reads it
    ///     via `"$(cat …)"` — no quoting of arbitrary text into the command line.
    ///   - workingDirectory: nil starts in the user's home directory.
    static func launch(prompt: String, harnessKey: String, config: PromptConfig,
                       context: PromptContext, checkout: Bool,
                       workingDirectory: String?, promptFile: String) throws -> PromptLaunch {
        if let error = validate(harnessKey: harnessKey, config: config).first { throw error }
        let harness = config.harnesses[harnessKey]!

        if let urlTemplate = harness.url {
            let filled = try substitute(urlTemplate, context: context,
                                        prompt: percentEncode(prompt), transform: percentEncode)
            guard let url = URL(string: filled) else { throw PromptError.harnessHasNoTarget(harnessKey) }
            return .web(url)
        }

        let command = try substitute(harness.command ?? "", context: context,
                                     prompt: "\"$(cat \(shellQuote(promptFile)))\"", transform: shellQuote)

        var lines = ["#!/bin/zsh -il"]
        if let dir = workingDirectory { lines.append("cd \(shellQuote(dir)) || exit 1") }
        if checkout, workingDirectory != nil {
            if let bad = quotedPlaceholders(in: config.checkout).first { throw PromptError.placeholderInQuotes(bad) }
            let pre = try substitute(config.checkout, context: context, transform: shellQuote)
            if !pre.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(pre + " || echo '⚠︎ checkout failed — continuing on the current branch'")
            }
        }
        lines.append(command)
        return .terminal(script: lines.joined(separator: "\n") + "\n", promptText: prompt)
    }

    // MARK: Picker filtering

    /// Case-insensitive match on name or harness label; empty query keeps everything.
    static func filter(_ templates: [PromptTemplate], query: String, config: PromptConfig) -> [PromptTemplate] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return templates }
        return templates.filter { t in
            t.name.lowercased().contains(q)
                || (config.harnesses[t.harness]?.label.lowercased().contains(q) ?? false)
        }
    }

    /// Wraps a free-typed prompt with the PR it is about.
    static func customBody(_ typed: String) -> String {
        "Regarding {{pr.url}} ({{pr.title}}):\n\n\(typed)"
    }
}

// MARK: - Starter files

enum PromptStarters {
    static let readme = """
    Mainline prompt templates
    =========================

    Each *.md file in this folder is one template. Right-click a PR → "Run prompt",
    or press the Prompt key (default A) in the deck, to pick one. Edits here show up
    in Mainline immediately; you can also edit them in Settings → Prompts.

    File format
    -----------
        ---
        # Whole-line comments like this one are ignored (not trailing ones).
        name: Review PR
        harness: claude
        checkout: true
        ---
        Your prompt. Placeholders: {{pr.url}} {{pr.number}} {{pr.title}} {{pr.repo}}
        {{pr.owner}} {{pr.branch}} {{pr.base}} {{pr.author}}

    config.json
    -----------
    "harnesses" maps a key to either a `command` (run in your terminal) or a `url`
    (opened in your browser). It MUST contain {{prompt}} — that is where the rendered
    template goes. Mainline refuses to run a harness that doesn't, so you always
    control how the prompt is passed:

        "claude": { "label": "Claude Code", "command": "claude {{prompt}}" }
        "agent0": { "label": "Agent0",      "url": "https://app.dash0.com/agent0?prompt={{prompt}}" }

    "order" lists harness keys by priority (first = default: the one a free-typed
    prompt asks first). Set "enabled": false on a harness to hide it and refuse to
    run it. Settings → Prompts edits both with a toggle and up/down buttons.

    In a url, {{prompt}} is percent-encoded for you. In a command it expands to the
    prompt as a single shell argument.

    "repos" maps owner/repo to your local clone, so CLI harnesses start there:

        "repos": { "dash0hq/dash0": "~/Workspace/dash0.git/main" }

    "checkout" is the command a template runs first when it sets `checkout: true`
    (default: gh pr checkout {{pr.number}}; e.g. `gw checkout {{pr.branch}}`).
    Without a repos entry a CLI harness starts in ~ and the checkout is skipped.

    Don't wrap {{pr.*}} placeholders in quotes inside a command or checkout step:
    Mainline already quotes each value safely, and extra quotes would defeat that
    (a PR title is untrusted text). Mainline refuses to run such a command.
    """

    /// The first starter is written WITH comments so opening it teaches the format;
    /// the parser ignores `#` lines in the frontmatter.
    static func fileContents(for t: PromptTemplate) -> String {
        guard t.fileName == "review-pr.md" else { return PromptEngine.serialize(t) }
        return """
        ---
        # Each *.md file in this folder is one template (see README.txt).
        # name: what the picker and the right-click menu show.
        name: \(t.name)
        # harness: a key from ../config.json "harnesses" (claude, codex, amp, opencode, agent0, or your own).
        harness: \(t.harness)
        # checkout: true runs config.json's "checkout" step in the repo's local clone first.
        #           Needs the repo listed under "repos" in config.json.
        checkout: true
        # Everything below the closing --- is the prompt, sent as-is, with these filled in:
        # {{pr.url}} {{pr.number}} {{pr.title}} {{pr.repo}} {{pr.owner}} {{pr.branch}} {{pr.base}} {{pr.author}}
        ---
        \(t.body)

        """
    }

    static let templates: [PromptTemplate] = [
        PromptTemplate(
            fileName: "review-pr.md", name: "Review PR", harness: "claude", checkout: true,
            body: """
            Review {{pr.url}} — "{{pr.title}}" ({{pr.branch}} → {{pr.base}}).
            Focus on correctness, missed edge cases and unresolved review threads.
            Report findings ranked by severity; don't change any code.
            """),
        PromptTemplate(
            fileName: "address-feedback.md", name: "Address review feedback", harness: "codex", checkout: true,
            body: """
            Read the review comments on {{pr.url}} and address each unresolved thread
            on this branch ({{pr.branch}}). Commit each fix separately.
            """),
        PromptTemplate(
            fileName: "investigate-ci.md", name: "Investigate failing CI", harness: "agent0", checkout: false,
            body: """
            CI is failing on {{pr.url}} ({{pr.repo}}#{{pr.number}}). Find the cause
            and suggest a fix.
            """),
    ]
}

// MARK: - Checks

#if DEBUG
enum PromptTemplateChecks {
    static func run() {
        let ctx = PromptContext(values: [
            "pr.url": "https://github.com/o/r/pull/12", "pr.number": "12", "pr.title": "feat: it's & more",
            "pr.repo": "o/r", "pr.owner": "o", "pr.branch": "feat/x", "pr.base": "main", "pr.author": "me",
        ])
        let cfg = PromptConfig.default
        let tpl0 = PromptTemplate(fileName: "q.md", name: "q", harness: "claude", checkout: false, body: "x")

        // Parse: frontmatter, comments, fallback name.
        let t = PromptEngine.parse(fileName: "a.md", text: "---\nname: Fix #123 regressions\n# note\nharness: codex\ncheckout: true\n---\nBody {{pr.url}}\n")!
        assert(t.name == "Fix #123 regressions" && t.harness == "codex" && t.checkout && t.body == "Body {{pr.url}}", "frontmatter parse")
        let bare = PromptEngine.parse(fileName: "plain-one.md", text: "just text")!
        assert(bare.name == "plain-one" && bare.harness == "claude" && !bare.checkout && bare.body == "just text", "no frontmatter")
        assert(PromptEngine.parse(fileName: "r.md", text: PromptEngine.serialize(t)) == PromptTemplate(
            fileName: "r.md", name: t.name, harness: t.harness, checkout: t.checkout, body: t.body), "serialize round-trips")

        // File names.
        assert(PromptEngine.fileName(forName: "Review PR!", existing: []) == "review-pr.md", "slug")
        assert(PromptEngine.fileName(forName: "Review PR", existing: ["review-pr.md"]) == "review-pr-2.md", "dedupe")
        assert(PromptEngine.fileName(forName: "???", existing: []) == "template.md", "empty slug")

        // Validation: {{prompt}} required; unknown harness / placeholder flagged.
        var bad = cfg
        bad.harnesses["claude"] = HarnessConfig(label: "C", command: "claude", url: nil)
        assert(PromptEngine.validate(harnessKey: "claude", config: bad) == [.missingPromptPlaceholder(harness: "claude")], "missing {{prompt}}")
        assert(PromptEngine.validate(harnessKey: "nope", config: cfg) == [.unknownHarness("nope")], "unknown harness")
        assert(PromptEngine.validate(harnessKey: "agent0", config: cfg).isEmpty, "defaults valid")
        var withBadPlaceholder = t; withBadPlaceholder.body = "{{pr.nope}}"; withBadPlaceholder.harness = "claude"
        assert(PromptEngine.validate(withBadPlaceholder, config: cfg) == [.unknownPlaceholder("pr.nope")], "unknown placeholder")
        for h in cfg.harnesses.keys { assert(PromptEngine.validate(harnessKey: h, config: cfg).isEmpty, "default harness \(h) has {{prompt}}") }

        // Placeholders inside shell quotes are rejected (injection via a PR title/branch).
        assert(PromptEngine.quotedPlaceholders(in: "gw checkout \"{{pr.branch}}\"") == ["pr.branch"], "double-quoted pr value")
        assert(PromptEngine.quotedPlaceholders(in: "echo '{{pr.title}}'") == ["pr.title"], "single-quoted pr value")
        assert(PromptEngine.quotedPlaceholders(in: "claude \"x {{prompt}}\"").isEmpty, "{{prompt}} in double quotes is fine")
        assert(PromptEngine.quotedPlaceholders(in: "claude '{{prompt}}'") == ["prompt"], "{{prompt}} in single quotes breaks")
        assert(PromptEngine.quotedPlaceholders(in: "claude {{prompt}} --x {{pr.url}}").isEmpty, "unquoted is fine")
        assert(PromptEngine.quotedPlaceholders(in: "echo \\\"{{pr.title}}").isEmpty, "escaped quote opens nothing")
        var quotedHarness = cfg
        quotedHarness.harnesses["claude"] = HarnessConfig(label: "C", command: "claude --t \"{{pr.title}}\" {{prompt}}", url: nil)
        assert(PromptEngine.validate(harnessKey: "claude", config: quotedHarness) == [.placeholderInQuotes("pr.title")], "validate flags it")
        var quotedCheckout = cfg
        quotedCheckout.checkout = "gw checkout \"{{pr.branch}}\""
        var wantsCheckout = tpl0; wantsCheckout.checkout = true
        assert(PromptEngine.validate(wantsCheckout, config: quotedCheckout) == [.placeholderInQuotes("pr.branch")], "checkout step flagged")
        assert((try? PromptEngine.launch(prompt: "p", harnessKey: "claude", config: quotedCheckout, context: ctx,
                                         checkout: true, workingDirectory: "/tmp", promptFile: "/tmp/p")) == nil, "launch refuses a quoted checkout")

        // Harness priority + enable/disable.
        assert(cfg.orderedHarnesses.map(\.key) == ["claude", "codex", "amp", "opencode", "agent0"], "default priority order")
        var custom = cfg
        custom.harnesses["zed"] = HarnessConfig(label: "Zed", command: "zed {{prompt}}", url: nil)
        custom.harnesses["aaa"] = HarnessConfig(label: "Aaa", command: "aaa {{prompt}}", url: nil)
        assert(Array(custom.orderedHarnesses.map(\.key).suffix(2)) == ["aaa", "zed"], "unlisted harnesses follow, by label")
        let promoted = custom.moving("agent0", by: -4)
        assert(promoted.orderedHarnesses.first?.key == "agent0", "move to the top")
        assert(promoted.moving("agent0", by: -1) == promoted, "no-op at the top")
        assert(cfg.moving("opencode", by: 1).order.suffix(2) == ["agent0", "opencode"], "move down swaps with its neighbour")
        let off = cfg.settingEnabled("claude", false)
        assert(off.enabledHarnesses.first?.key == "codex", "disabled harness drops out; next is the default")
        assert(off.orderedHarnesses.first?.key == "claude", "…but stays listed for Settings")
        assert(PromptEngine.validate(harnessKey: "claude", config: off) == [.harnessDisabled("claude")], "disabled harness refuses to run")
        assert(off.settingEnabled("claude", true) == cfg, "re-enabling restores the exact config")
        assert((try? JSONDecoder().decode(PromptConfig.self, from: JSONEncoder().encode(off))) == off, "enabled/order survive JSON")
        let noOrder = try? JSONDecoder().decode(PromptConfig.self, from: Data("{\"harnesses\":{\"b\":{\"label\":\"B\",\"command\":\"b {{prompt}}\"},\"a\":{\"label\":\"A\",\"command\":\"a {{prompt}}\",\"enabled\":false}}}".utf8))
        assert(noOrder?.orderedHarnesses.map(\.key) == ["a", "b"] && noOrder?.enabledHarnesses.map(\.key) == ["b"], "order absent → by label; enabled:false honoured")

        // A hand-edited config missing sections keeps their defaults.
        let partial = try? JSONDecoder().decode(PromptConfig.self, from: Data("{\"repos\":{\"a/b\":\"~/x\"}}".utf8))
        assert(partial?.repos == ["a/b": "~/x"] && partial?.checkout == cfg.checkout && partial?.harnesses == cfg.harnesses, "lenient config decode")

        // Rendering.
        let tpl = PromptTemplate(fileName: "x.md", name: "x", harness: "claude", checkout: false, body: "See {{ pr.url }} on {{pr.branch}}")
        assert((try? PromptEngine.renderBody(tpl, context: ctx)) == "See https://github.com/o/r/pull/12 on feat/x", "render")
        var recursive = tpl; recursive.body = "{{prompt}}"
        assert((try? PromptEngine.renderBody(recursive, context: ctx)) == nil, "{{prompt}} is reserved in bodies")

        // A PR title that looks like a placeholder stays inert text.
        var evil = ctx; evil.values["pr.title"] = "{{prompt}}"
        if case .terminal(let script, _)? = try? PromptEngine.launch(
            prompt: "p", harnessKey: "claude", config: PromptConfig(checkout: "", repos: [:], harnesses: [
                "claude": HarnessConfig(label: "C", command: "claude {{pr.title}} {{prompt}}", url: nil)]),
            context: evil, checkout: false, workingDirectory: nil, promptFile: "/tmp/p") {
            assert(script.contains("claude '{{prompt}}' \"$(cat '/tmp/p')\""), "values are not re-scanned")
        } else { assertionFailure("evil title launch") }

        // Web launch: the prompt is fully percent-encoded.
        if case .web(let url)? = try? PromptEngine.launch(prompt: "a&b=c #1 é", harnessKey: "agent0", config: cfg, context: ctx,
                                                           checkout: false, workingDirectory: nil, promptFile: "/tmp/p") {
            assert(url.absoluteString == "https://app.dash0.com/agent0?prompt=a%26b%3Dc%20%231%20%C3%A9", "web url encoding")
        } else { assertionFailure("web launch") }

        // CLI launch: cd, checkout, prompt read from file, hostile values quoted.
        if case .terminal(let script, let text)? = try? PromptEngine.launch(
            prompt: "hello '; rm -rf ~", harnessKey: "claude", config: cfg, context: ctx,
            checkout: true, workingDirectory: "/Users/me/my repo", promptFile: "/tmp/it's.txt") {
            assert(text == "hello '; rm -rf ~", "prompt text passed through verbatim")
            assert(script.contains("cd '/Users/me/my repo' || exit 1"), "cd quoted")
            assert(script.contains("gh pr checkout '12' ||"), "checkout runs with quoted placeholder")
            assert(script.contains("claude \"$(cat '/tmp/it'\\''s.txt')\""), "prompt via quoted file")
            assert(!script.contains("rm -rf"), "prompt text never appears in the script")
        } else { assertionFailure("cli launch") }
        if case .terminal(let script, _)? = try? PromptEngine.launch(
            prompt: "p", harnessKey: "claude", config: cfg, context: ctx,
            checkout: true, workingDirectory: nil, promptFile: "/tmp/p") {
            assert(!script.contains("checkout"), "no repo path → checkout skipped")
        } else { assertionFailure("cli launch without dir") }

        // Repo path lookup.
        var withRepo = cfg; withRepo.repos = ["Dash0hq/Dash0": "~/code"]
        assert(withRepo.localPath(forRepo: "dash0hq/dash0") == (("~/code") as NSString).expandingTildeInPath, "case-insensitive repo")
        assert(withRepo.localPath(forRepo: "x/y") == nil, "unmapped repo")

        // Filtering.
        let all = PromptStarters.templates
        assert(PromptEngine.filter(all, query: "", config: cfg).count == all.count, "empty query keeps all")
        assert(PromptEngine.filter(all, query: "REVIEW", config: cfg).map(\.fileName) == ["review-pr.md", "address-feedback.md"], "name match")
        assert(PromptEngine.filter(all, query: "agent0", config: cfg).map(\.fileName) == ["investigate-ci.md"], "harness-label match")

        // The annotated starter parses to the same template and sends no comment text.
        let review = PromptStarters.templates[0]
        let annotated = PromptEngine.parse(fileName: review.fileName, text: PromptStarters.fileContents(for: review))
        assert(annotated == review, "annotated starter parses back to itself")
        assert(annotated?.body.contains("#") == false, "frontmatter comments never reach the prompt")

        // Starters are all valid against the default config.
        for s in all { assert(PromptEngine.validate(s, config: cfg).isEmpty, "starter \(s.fileName) valid") }
        // Config round-trips as JSON.
        let data = try! JSONEncoder().encode(cfg)
        assert((try? JSONDecoder().decode(PromptConfig.self, from: data)) == cfg, "config JSON round-trip")
    }
}
#endif
