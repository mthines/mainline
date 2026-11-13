import Foundation

// MARK: - Model

/// A canned PR comment, one Markdown file in `~/.config/mainline/comments/`. Posting it
/// is how a repo's comment-triggered automation (an agent run, a bot command…) is started,
/// so which comments exist is scoped per org / repo through `scope`.
///
///     ---
///     name: Agent0: fix CI
///     scope: dash0hq/*, mthines/mainline
///     when: authored+ci-failing
///     priority: 10
///     ---
///     @agent0 fix the failing checks on {{pr.url}}
struct CommentTemplate: Identifiable, Equatable {
    /// File name inside the comments folder, e.g. `fix-ci.md`.
    var fileName: String
    var name: String
    /// Patterns the template is offered for: `owner/repo`, `owner/*` or `*`, case-insensitive.
    /// Empty = every repo.
    var scope: [String] = []
    /// Optional PR-state expression (same grammar as prompt templates) that floats the
    /// comment to the top of the picker when the PR is in that state.
    var when: String = ""
    var priority: Int = 0
    var body: String

    var id: String { fileName }

    /// `scope` as it is written in the file (`a, b`).
    var scopeText: String { scope.joined(separator: ", ") }
}

// MARK: - Engine (pure)

enum CommentEngine {
    // MARK: Parse / serialize

    /// Parses a comment file. A file without frontmatter is still a comment, named after
    /// its file. Returns nil only when there is no usable name.
    static func parse(fileName: String, text: String) -> CommentTemplate? {
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
                    meta[key] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        let fallbackName = (fileName as NSString).deletingPathExtension
        let name = (meta["name"]?.isEmpty == false ? meta["name"]! : fallbackName)
        guard !name.isEmpty else { return nil }
        return CommentTemplate(
            fileName: fileName,
            name: name,
            scope: parseScope(meta["scope"] ?? ""),
            when: meta["when"] ?? "",
            priority: Int(meta["priority"] ?? "") ?? 0,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func parseScope(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func serialize(_ t: CommentTemplate) -> String {
        var lines = ["---", "name: \(t.name)"]
        if !t.scope.isEmpty { lines.append("scope: \(t.scopeText)") }
        if !t.when.isEmpty { lines.append("when: \(t.when)") }
        if t.priority != 0 { lines.append("priority: \(t.priority)") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + t.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// A unique, filesystem-safe `.md` name for a new comment.
    static func fileName(forName name: String, existing: Set<String>) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let base = slug.isEmpty ? "comment" : slug
        var candidate = "\(base).md"
        var n = 2
        while existing.contains(candidate) { candidate = "\(base)-\(n).md"; n += 1 }
        return candidate
    }

    // MARK: Scope

    /// Whether `pattern` (`*`, `owner/*`, `owner/repo`) covers `repo` (`owner/repo`).
    static func patternMatches(_ pattern: String, repo: String) -> Bool {
        let p = pattern.lowercased(), r = repo.lowercased()
        if p == "*" { return true }
        if p.hasSuffix("/*") { return r.hasPrefix(String(p.dropLast())) }
        return p == r
    }

    /// Offered for `repo`: an empty scope means everywhere.
    static func appliesTo(_ t: CommentTemplate, repo: String) -> Bool {
        t.scope.isEmpty || t.scope.contains { patternMatches($0, repo: repo) }
    }

    // MARK: Validate / render

    /// Placeholders a comment may use: the single PR's `{{pr.*}}` facts.
    static let placeholderNames = PromptContext.placeholderNames.filter { $0.hasPrefix("pr.") }

    static func validate(_ t: CommentTemplate) -> [PromptError] {
        var errors: [PromptError] = []
        for name in PromptEngine.placeholders(in: t.body) where !placeholderNames.contains(name) {
            errors.append(.unknownPlaceholder(name))
        }
        for token in PromptState.parse(t.when).unknown { errors.append(.unknownStateToken(token)) }
        return errors
    }

    /// The comment text for `pr`. Throws on an unknown placeholder or an empty result.
    static func render(_ t: CommentTemplate, for pr: PRSnapshot) throws -> String {
        if let error = validate(t).first(where: { if case .unknownPlaceholder = $0 { return true } else { return false } }) {
            throw error
        }
        let text = try PromptEngine.substitute(t.body, context: PromptContext(pr: pr))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommentError.empty }
        return text
    }

    // MARK: Picker ordering + filtering

    struct Ranked: Equatable {
        var template: CommentTemplate
        /// Why it is suggested for this PR; nil = not suggested.
        var reason: String?
    }

    /// The comments offered for a PR in `repo`: scoped, suggested first (priority high → low,
    /// ties keep file order), the rest in file order.
    static func ordered(_ templates: [CommentTemplate], repo: String, active: Set<String>) -> [Ranked] {
        let ranked = templates.filter { appliesTo($0, repo: repo) }.map {
            Ranked(template: $0, reason: validate($0).isEmpty ? PromptState.matchedAlternative($0.when, active: active) : nil)
        }
        let suggested = ranked.enumerated().filter { $0.element.reason != nil }
            .sorted { a, b in
                a.element.template.priority != b.element.template.priority
                    ? a.element.template.priority > b.element.template.priority
                    : a.offset < b.offset
            }.map(\.element)
        return suggested + ranked.filter { $0.reason == nil }
    }

    /// Case-insensitive match on the name or the text; empty query keeps everything.
    static func filter(_ ranked: [Ranked], query: String) -> [Ranked] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ranked }
        return ranked.filter { $0.template.name.lowercased().contains(q) || $0.template.body.lowercased().contains(q) }
    }
}

enum CommentError: Error, LocalizedError, Equatable {
    case empty
    case writeActionsOff

    var errorDescription: String? {
        switch self {
        case .empty: return "That comment is empty."
        case .writeActionsOff: return "Turn on write actions in Settings to post comments."
        }
    }
}

// MARK: - Starter README

enum CommentStarters {
    static let readme = """
    Mainline comment templates
    ==========================

    Each .md file here is one canned PR comment. Press the Comment key in the deck
    (default W) or right-click a PR → Comment, type to filter, press Return, and the
    comment is posted on the PR. Use it to start a comment-triggered automation, e.g. an
    agent run that reacts to "@agent0 fix CI". Posting needs write actions enabled.

    File format:

        ---
        name: Fix failing CI
        scope: acme/*, me/side-project
        when: authored+ci-failing
        priority: 10
        ---
        @agent0 fix the failing checks on {{pr.url}}

    name      Shown in the picker. Defaults to the file name.
    scope     Where it is offered: owner/repo, owner/* or *, comma-separated.
              Leave it out to offer the comment on every repo.
    when      Optional. PR states that float it to the top (same tokens as prompt
              templates: ci-failing, conflict, authored, reviewing, draft … , = or, + = and, ! = not).
    priority  Optional. Higher floats first among suggested comments.

    Placeholders: {{pr.url}} {{pr.number}} {{pr.title}} {{pr.repo}} {{pr.owner}}
                  {{pr.branch}} {{pr.base}} {{pr.author}}

    Text you type in the picker instead of choosing a template is posted as-is.
    """
}

// MARK: - Self-checks

#if DEBUG
enum CommentTemplateChecks {
    static func run() {
        // Scope matching: exact, org wildcard, global, case-insensitive; empty = everywhere.
        assert(CommentEngine.patternMatches("acme/api", repo: "Acme/API"))
        assert(CommentEngine.patternMatches("acme/*", repo: "acme/web"))
        assert(!CommentEngine.patternMatches("acme/*", repo: "acmecorp/web"))
        assert(!CommentEngine.patternMatches("acme/api", repo: "acme/web"))
        assert(CommentEngine.patternMatches("*", repo: "any/thing"))

        let scoped = CommentTemplate(fileName: "a.md", name: "A", scope: ["acme/*"], body: "x")
        let everywhere = CommentTemplate(fileName: "b.md", name: "B", body: "y")
        assert(CommentEngine.appliesTo(scoped, repo: "acme/web"))
        assert(!CommentEngine.appliesTo(scoped, repo: "other/web"))
        assert(CommentEngine.appliesTo(everywhere, repo: "other/web"))

        // Round trip.
        let t = CommentTemplate(fileName: "fix.md", name: "Fix CI", scope: ["acme/*", "me/x"],
                                when: "authored+ci-failing", priority: 5, body: "@bot fix {{pr.url}}")
        assert(CommentEngine.parse(fileName: "fix.md", text: CommentEngine.serialize(t)) == t)

        // No frontmatter: still a comment, named after the file.
        let bare = CommentEngine.parse(fileName: "ping.md", text: "@bot ping")
        assert(bare?.name == "ping" && bare?.body == "@bot ping" && bare?.scope.isEmpty == true)

        // Validation: only {{pr.*}}; a bad `when` token is flagged.
        assert(CommentEngine.validate(CommentTemplate(fileName: "c.md", name: "C", body: "{{pr.url}}")).isEmpty)
        assert(!CommentEngine.validate(CommentTemplate(fileName: "c.md", name: "C", body: "{{stack.size}}")).isEmpty)
        assert(!CommentEngine.validate(CommentTemplate(fileName: "c.md", name: "C", body: "{{prompt}}")).isEmpty)
        assert(!CommentEngine.validate(CommentTemplate(fileName: "c.md", name: "C", when: "nonsense-state", body: "x")).isEmpty)

        // Ordering: scoped out, suggested first by priority, rest in file order.
        let a = CommentTemplate(fileName: "a.md", name: "A", body: "a")
        let b = CommentTemplate(fileName: "b.md", name: "B", when: "authored", priority: 1, body: "b")
        let c = CommentTemplate(fileName: "c.md", name: "C", when: "authored", priority: 9, body: "c")
        let out = CommentTemplate(fileName: "d.md", name: "D", scope: ["other/*"], body: "d")
        let ranked = CommentEngine.ordered([a, b, c, out], repo: "acme/web", active: ["authored"])
        assert(ranked.map(\.template.fileName) == ["c.md", "b.md", "a.md"])
        assert(CommentEngine.filter(ranked, query: "b").map(\.template.fileName) == ["b.md"])

        // Filename slugs are unique.
        assert(CommentEngine.fileName(forName: "Fix CI!", existing: ["fix-ci.md"]) == "fix-ci-2.md")
    }
}
#endif
