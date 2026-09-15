import Foundation

// MARK: - PRSearchFilter

/// Pure matcher for the in-app PR search box (opened with the `search` shortcut).
///
/// Parses a raw query into one of a few interpretations and decides whether a
/// `PRSnapshot` matches. It exists so you can paste a bare PR number (`200`), a
/// `#200`, or a full GitHub PR URL and have the list narrow to that PR — while
/// still supporting free-text search across title / repo / author / branch.
///
/// No I/O and no state → a member of the pure-shell family, assertable via
/// `runSelfChecks()` (wired from `MainlineApp` in DEBUG, like the other engines).
enum PRSearchFilter {

    /// A parsed interpretation of the raw query string.
    enum Query: Equatable {
        /// A GitHub PR URL — match BOTH the repo (`owner/repo`) and the number, so
        /// pasting a full link resolves to exactly one PR even across repos that
        /// happen to share a number.
        case url(repoFullName: String, number: Int)
        /// A bare number / `#123` — match the number across every repo (you rarely
        /// remember which repo a number lives in).
        case number(Int)
        /// Free text — case-insensitive substring across the searchable fields.
        case text(String)
        /// Empty / whitespace-only — matches everything (the field is open but blank).
        case empty
    }

    /// Parses a raw query. Tiers, most specific first: PR URL → bare number → text.
    static func parse(_ raw: String) -> Query {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if let url = parsePRURL(trimmed) { return url }
        if let n = bareNumber(trimmed) { return .number(n) }
        return .text(trimmed.lowercased())
    }

    /// Whether a snapshot matches the query.
    static func matches(_ pr: PRSnapshot, query raw: String) -> Bool {
        switch parse(raw) {
        case .empty:
            return true
        case .url(let repo, let number):
            return pr.number == number
                && pr.repoFullName.caseInsensitiveCompare(repo) == .orderedSame
        case .number(let number):
            return pr.number == number
        case .text(let needle):
            return haystack(for: pr).contains(needle)
        }
    }

    // MARK: - Helpers

    /// Lowercased concatenation of every user-facing field worth searching, incl.
    /// a `#<number>` token so typing `#200` as free text (when it isn't the whole
    /// query) still hits.
    private static func haystack(for pr: PRSnapshot) -> String {
        "\(pr.title) \(pr.repoFullName) \(pr.author) \(pr.headRefName) #\(pr.number)"
            .lowercased()
    }

    /// Extracts a bare PR number from a WHOLE-string query: `200`, `#200`, `  200 `.
    /// Returns nil unless the entire (trimmed) query is a run of digits with an
    /// optional leading `#` — so `200 auth` stays free text, not a number match.
    static func bareNumber(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard !t.isEmpty, t.allSatisfy(\.isNumber) else { return nil }
        return Int(t)
    }

    /// Parses `<owner>/<repo>/pull/<n>` out of any GitHub PR URL or path, ignoring
    /// scheme/host and any trailing `/files`, `#…`, `?…`. Accepts `/pull/` and the
    /// rarer `/pulls/`. Falls back to `.number` when the repo can't be recovered.
    static func parsePRURL(_ s: String) -> Query? {
        // Search case-insensitively on `s` itself so every index below indexes into
        // the SAME string. Computing the marker range on `s.lowercased()` and then
        // slicing `s` with it is a latent bug: `String.Index` is instance-specific,
        // so any character before the marker whose lowercase form differs in UTF-8
        // length shifts the mapping and the number/repo parse off the wrong offset.
        guard let marker = s.range(of: "/pull/", options: .caseInsensitive)
                ?? s.range(of: "/pulls/", options: .caseInsensitive) else {
            return nil
        }
        // Number: the digit run immediately after the marker.
        let digits = s[marker.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        // Repo: the two path components immediately before the marker. Strip scheme
        // so the host doesn't get counted as a component.
        let beforePull = String(s[..<marker.lowerBound])
            .replacingOccurrences(of: "https://", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "http://", with: "", options: .caseInsensitive)
        let comps = beforePull.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return .number(number) }
        let repo = "\(comps[comps.count - 2])/\(comps[comps.count - 1])"
        return .url(repoFullName: repo, number: number)
    }

    #if DEBUG
    /// Asserts the parser + matcher invariants at launch (no-op in Release).
    static func runSelfChecks() {
        // parse — bare numbers
        assert(parse("200") == .number(200))
        assert(parse("#200") == .number(200))
        assert(parse("  42 ") == .number(42))
        // parse — URLs (with and without scheme, trailing path)
        assert(parse("https://github.com/acme/web/pull/200") == .url(repoFullName: "acme/web", number: 200))
        assert(parse("https://github.com/acme/web/pull/200/files") == .url(repoFullName: "acme/web", number: 200))
        assert(parse("github.com/acme/web/pull/200") == .url(repoFullName: "acme/web", number: 200))
        // parse — a non-ASCII char before the marker must not shift the number/repo
        // offsets (regression guard: indices must index into the same string).
        assert(parse("İ/acme/web/pull/200") == .url(repoFullName: "acme/web", number: 200))
        // parse — free text and empty
        assert(parse("auth flow") == .text("auth flow"))
        assert(parse("200 auth") == .text("200 auth"))   // not a whole-number query
        assert(parse("   ") == .empty)

        let pr = PRSnapshot(
            nodeId: "1", number: 200, title: "Fix auth flow", htmlUrl: "",
            repoFullName: "acme/web", isDraft: false, state: "open",
            ciStatus: .success, reviewState: .none, commentCount: 0,
            updatedAt: "", author: "octocat", requestedReviewers: [],
            headRefName: "feat/auth"
        )
        // number / url matching
        assert(matches(pr, query: "200"))
        assert(matches(pr, query: "#200"))
        assert(matches(pr, query: "https://github.com/acme/web/pull/200"))
        assert(!matches(pr, query: "201"))
        // url with a different repo but same number must NOT match
        assert(!matches(pr, query: "https://github.com/other/repo/pull/200"))
        // free-text across fields (case-insensitive)
        assert(matches(pr, query: "AUTH"))
        assert(matches(pr, query: "acme/web"))
        assert(matches(pr, query: "octocat"))
        assert(matches(pr, query: "feat/auth"))
        assert(!matches(pr, query: "nonsense"))
        // empty query matches everything
        assert(matches(pr, query: "   "))
    }
    #endif
}
