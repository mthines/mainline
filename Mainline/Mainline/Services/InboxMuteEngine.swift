import Foundation

// MARK: - MuteReason

/// The discriminated reason a PR was demoted to the Muted group.
/// First-match-wins: the engine walks the rules in order and returns the
/// first non-nil reason.
enum MuteReason {
    case pattern(String)   // matched a mutePatterns glob (the matching pattern)
    case botAuthor         // author is a bot and muteBotAuthors is on
    case label(String)     // carries a label in muteLabels (the matching label)
    case outsideFocus      // outside this org's focus allow-list (Needs-your-review only)
}

// MARK: - OrgFocusConfig

/// Per-org review-focus allow-lists. A team slug (and, by extension, the notion
/// of "who matters to review here") is org-local — `ai` in `dash0hq` is unrelated
/// to any `ai` elsewhere — so focus is keyed by org rather than applied globally.
///
/// Semantics: an org whose config is absent OR `isEmpty` has NO focus rule, so
/// every one of its PRs stays active. Focus only ever demotes within an org that
/// has a non-empty rule — nothing entered for one org can mute PRs in another.
struct OrgFocusConfig: Codable, Equatable {
    var authors: [String]   // allow-list of author logins (case-insensitive)
    var teams: [String]     // allow-list of team slugs (case-insensitive)

    var isEmpty: Bool { authors.isEmpty && teams.isEmpty }

    static let empty = OrgFocusConfig(authors: [], teams: [])
}

// MARK: - InboxMuteConfig

/// Plain-value config built by the impure shell (PRManager) from MainlineSettings.
/// Passed to the pure engine so the engine has zero dependency on MainlineSettings.
struct InboxMuteConfig {
    var mutePatterns: [String]               // glob patterns for title/headRef (case-insensitive, * wildcard)
    var muteBotAuthors: Bool                 // demote bot-authored PRs
    var botAllowList: [String]               // logins exempt from muteBotAuthors (case-insensitive; empty = no exceptions)
    var focusByOrg: [String: OrgFocusConfig] // per-org review-focus allow-lists (org missing/empty = show all of that org)
    var muteLabels: [String]                 // labels to demote (empty = disabled)
    var myLogin: String                      // authenticated user's login (for role derivation)
}

// MARK: - InboxMuteEngine

/// Pure, stateless engine for Inbox mute-rule evaluation.
/// No I/O, no ObservableObject, no MainlineSettings access — mirrors the
/// `TriageClassifier` / `SensitivePathMatcher` pure-enum pattern.
enum InboxMuteEngine {

    // MARK: - Public API

    /// Returns the first mute reason that applies to this PR, or nil if no rule
    /// fires. The caller places a non-nil result in the shared Muted group.
    ///
    /// Rule order (first match wins):
    ///   1. Title/branch pattern glob
    ///   2. Bot author (when muteBotAuthors is on)
    ///   3. Label match
    ///   4. Outside this org's focus allow-list (Needs-your-review role only)
    static func muteVerdict(
        title: String,
        headRef: String,
        authorLogin: String,
        authorIsBot: Bool,
        requestedTeams: [String],
        labels: [String],
        org: String,
        role: InboxRole,
        config: InboxMuteConfig
    ) -> MuteReason? {
        // Rule 1 — title/branch pattern
        for pattern in config.mutePatterns where !pattern.isEmpty {
            if matches(text: title,   glob: pattern) { return .pattern(pattern) }
            if matches(text: headRef, glob: pattern) { return .pattern(pattern) }
        }

        // Rule 2 — bot author (skipped for logins in botAllowList)
        if config.muteBotAuthors, authorIsBot || isBotLogin(authorLogin) {
            // Normalize the `[bot]` suffix on BOTH sides before comparing: GitHub's
            // GraphQL API returns bot author logins WITHOUT the suffix (e.g.
            // `dash0-dev`), while the display form and the Settings UI use the
            // suffixed form (e.g. `dash0-dev[bot]`). Comparing raw would make an
            // exception entered as `dash0-dev[bot]` never match the bare login.
            let login = normalizeBotLogin(authorLogin)
            let allowed = config.botAllowList.contains { normalizeBotLogin($0) == login }
            if !allowed { return .botAuthor }
        }

        // Rule 3 — label
        if !config.muteLabels.isEmpty {
            for label in labels {
                if config.muteLabels.contains(where: { $0.lowercased() == label.lowercased() }) {
                    return .label(label)
                }
            }
        }

        // Rule 4 — outside focus (Needs-your-review only; never applies to Your PRs).
        // Focus is per-org: only the PR's OWN org's rule applies. An org with no
        // entry (or an empty one) never focus-mutes — so a focus rule scoped to one
        // org can't demote PRs in another. This is what keeps a `dash0hq` team focus
        // from muting your personal `mthines/*` PRs.
        if role == .needsYourReview, let focus = focusConfig(for: org, in: config), !focus.isEmpty {
            // Normalize the `[bot]` suffix on both sides, mirroring Rule 2's bot
            // allow-list: a focus entry typed as `dash0-dev[bot]` must still match
            // the bare GraphQL login `dash0-dev` (and vice-versa). For a human login
            // (no suffix) this is just a lowercase compare, so it stays correct.
            let normalizedAuthor = normalizeBotLogin(authorLogin)
            let authorInFocus = focus.authors.contains { normalizeBotLogin($0) == normalizedAuthor }
            let teamInFocus = requestedTeams.contains { team in
                focus.teams.contains(where: { $0.lowercased() == team.lowercased() })
            }
            if !authorInFocus && !teamInFocus {
                return .outsideFocus
            }
        }

        return nil
    }

    /// Case-insensitive lookup of an org's focus config (GitHub org logins are
    /// case-insensitive, so `DASH0HQ` and `dash0hq` are the same org).
    static func focusConfig(for org: String, in config: InboxMuteConfig) -> OrgFocusConfig? {
        let key = org.lowercased()
        return config.focusByOrg.first { $0.key.lowercased() == key }?.value
    }

    // MARK: - Glob matcher (case-insensitive, * wildcard only)

    /// Returns true when `text` matches `glob` (case-insensitive).
    /// Only `*` is treated as a wildcard (matches zero or more characters);
    /// all other characters are matched literally. This mirrors common
    /// `.gitignore`-style "simple glob" semantics without the full complexity
    /// of `fnmatch`.
    static func matches(text: String, glob: String) -> Bool {
        let t = text.lowercased()
        let g = glob.lowercased()
        return globMatch(text: t[t.startIndex...], pattern: g[g.startIndex...])
    }

    // MARK: - Known bot logins

    /// Returns true if the login belongs to a well-known dependency-management bot
    /// (case-insensitive). Complements the `[bot]`-suffix heuristic already in
    /// `PRSnapshot.isBot` — together they cover the common bot logins seen in the
    /// wild without requiring GitHub's `__typename == "Bot"` to be populated.
    static func isBotLogin(_ login: String) -> Bool {
        let lower = login.lowercased()
        // Suffix heuristic: any login ending in [bot] is a bot.
        if lower.hasSuffix("[bot]") { return true }
        // Known bot base names (without the [bot] suffix variant).
        let knownBots: Set<String> = [
            "dependabot", "renovate", "github-actions"
        ]
        return knownBots.contains(lower)
    }

    /// Normalizes a login for allow-list comparison: lowercased with any trailing
    /// `[bot]` suffix removed. GitHub's GraphQL API returns bot author logins
    /// WITHOUT the suffix (`dependabot`), whereas the display form and the Settings
    /// UI use the suffixed form (`dependabot[bot]`). Normalizing both sides lets an
    /// exception entered in EITHER form match the actual author login.
    static func normalizeBotLogin(_ login: String) -> String {
        let lower = login.lowercased()
        if lower.hasSuffix("[bot]") {
            return String(lower.dropLast("[bot]".count))
        }
        return lower
    }

    // MARK: - Private glob implementation

    /// Recursive glob matcher. Both slices are already lowercased by the caller.
    private static func globMatch(
        text: Substring,
        pattern: Substring
    ) -> Bool {
        var t = text
        var p = pattern

        while !p.isEmpty {
            let pc = p.removeFirst()
            if pc == "*" {
                // Consume any number of text characters and try to match the rest.
                // First try matching zero characters (greedy would also work but
                // iterating from 0 covers the short-circuit case cheaply).
                if globMatch(text: t, pattern: p) { return true }
                while !t.isEmpty {
                    t.removeFirst()
                    if globMatch(text: t, pattern: p) { return true }
                }
                return false
            } else {
                // Literal character — must match exactly.
                guard !t.isEmpty, t.removeFirst() == pc else { return false }
            }
        }
        // Pattern exhausted — match only if text is also exhausted.
        return t.isEmpty
    }

    // MARK: - DEBUG self-check

    #if DEBUG
    /// Asserts that the core mute-rule logic is correct. Invoked once at app
    /// launch in DEBUG builds from MainlineApp/AppDelegate. Failures surface as
    /// assertion failures in Xcode, never in production.
    static func runSelfChecks() {
        // --- Glob matcher ---
        assert(matches(text: "chore(deps): bump x", glob: "chore(deps)*"),
               "glob: chore(deps)* should match chore(deps): bump x")
        // `)` is a literal, so `chore(deps)*` must NOT match the `-dev` variant;
        // to catch every chore(deps…) form the pattern is `chore(deps*`.
        assert(!matches(text: "chore(deps-dev): update", glob: "chore(deps)*"),
               "glob: literal ')' means chore(deps)* must NOT match chore(deps-dev):")
        assert(matches(text: "chore(deps-dev): update", glob: "chore(deps*"),
               "glob: chore(deps* should match chore(deps-dev):")
        assert(matches(text: "build(deps): something", glob: "build(deps)*"),
               "glob: build(deps)* should match build(deps):")
        assert(!matches(text: "feature: deps", glob: "chore(deps)*"),
               "glob: chore(deps)* should NOT match feature: deps")
        assert(matches(text: "CHORE(DEPS): bump", glob: "chore(deps)*"),
               "glob: case-insensitive match should work")
        assert(matches(text: "anything", glob: "*"),
               "glob: * matches everything")
        assert(!matches(text: "abc", glob: "xyz"),
               "glob: literal mismatch")

        let base = InboxMuteConfig(
            mutePatterns: [],
            muteBotAuthors: false,
            botAllowList: [],
            focusByOrg: [:],
            muteLabels: [],
            myLogin: "alice"
        )

        // --- Pattern rule ---
        var cfg = base
        cfg.mutePatterns = ["chore(deps)*"]
        let r1 = muteVerdict(
            title: "chore(deps): bump lodash",
            headRef: "some-branch",
            authorLogin: "bob",
            authorIsBot: false,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        if case .pattern = r1 { } else { assertionFailure("Rule 1 (pattern) did not fire") }

        // --- Bot author rule ---
        cfg = base
        cfg.muteBotAuthors = true
        let r2 = muteVerdict(
            title: "chore: bump deps",
            headRef: "renovate/something",
            authorLogin: "renovate[bot]",
            authorIsBot: true,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        if case .botAuthor = r2 { } else { assertionFailure("Rule 2 (botAuthor) did not fire") }

        // --- Bot author allow-list: allowed bot must NOT be muted ---
        cfg = base
        cfg.muteBotAuthors = true
        cfg.botAllowList = ["release-bot[bot]"]
        let r2allow = muteVerdict(
            title: "chore: release v2.0",
            headRef: "release/v2.0",
            authorLogin: "release-bot[bot]",
            authorIsBot: true,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        assert(r2allow == nil, "Bot in botAllowList must NOT be muted even when muteBotAuthors is on")

        // --- Bot author allow-list: unlisted bot must still be muted ---
        let r2unlisted = muteVerdict(
            title: "chore: bump deps",
            headRef: "renovate/something",
            authorLogin: "renovate[bot]",
            authorIsBot: true,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        if case .botAuthor = r2unlisted { } else { assertionFailure("Unlisted bot must still be muted when muteBotAuthors is on") }

        // --- Bot author allow-list: `[bot]`-suffix normalization ---
        // GraphQL returns the bare login (`dash0-dev`) while the Settings UI
        // instructs users to enter the suffixed form (`dash0-dev[bot]`). The
        // exemption must still match across that mismatch (both directions).
        cfg = base
        cfg.muteBotAuthors = true
        cfg.botAllowList = ["dash0-dev[bot]"]   // user typed the suffixed form
        let r2suffix = muteVerdict(
            title: "feat: something",
            headRef: "feature/x",
            authorLogin: "dash0-dev",           // GraphQL bare login (no [bot])
            authorIsBot: true,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        assert(r2suffix == nil, "Suffixed allow-list entry must exempt the bare GraphQL bot login")

        cfg.botAllowList = ["dash0-dev"]        // user typed the bare form
        let r2bare = muteVerdict(
            title: "feat: something",
            headRef: "feature/x",
            authorLogin: "dash0-dev[bot]",      // suffixed login form
            authorIsBot: true,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        assert(r2bare == nil, "Bare allow-list entry must exempt the suffixed bot login")

        // --- Label rule ---
        cfg = base
        cfg.muteLabels = ["dependencies"]
        let r3 = muteVerdict(
            title: "some PR",
            headRef: "branch",
            authorLogin: "human",
            authorIsBot: false,
            requestedTeams: [],
            labels: ["dependencies", "bug"],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        if case .label = r3 { } else { assertionFailure("Rule 3 (label) did not fire") }

        // --- Focus rule: outside focus → demote (within the PR's own org) ---
        cfg = base
        cfg.focusByOrg = ["acme": OrgFocusConfig(authors: ["carol"], teams: [])]
        let r4 = muteVerdict(
            title: "some PR",
            headRef: "branch",
            authorLogin: "dave",    // not in focus list
            authorIsBot: false,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        if case .outsideFocus = r4 { } else { assertionFailure("Rule 4 (outsideFocus) did not fire for non-focus author") }

        // --- Focus rule gate: Your PRs are never demoted by focus ---
        let r4b = muteVerdict(
            title: "my PR",
            headRef: "branch",
            authorLogin: "alice",
            authorIsBot: false,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .yourPRs,
            config: cfg
        )
        assert(r4b == nil, "Focus rule MUST NOT apply to .yourPRs role")

        // --- Focus rule: in-focus author → not muted ---
        let r4c = muteVerdict(
            title: "some PR",
            headRef: "branch",
            authorLogin: "carol",   // in focus list
            authorIsBot: false,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        assert(r4c == nil, "Focus rule must NOT fire for author in focus list")

        // --- Focus rule is PER-ORG: a rule on one org must NOT mute another org ---
        // Regression guard for the bug where a `dash0hq` team focus silently muted
        // personal `mthines/*` PRs. `cfg` still has focus only for "acme".
        let r4d = muteVerdict(
            title: "some PR",
            headRef: "branch",
            authorLogin: "dave",        // not in acme's focus list…
            authorIsBot: false,
            requestedTeams: [],
            labels: [],
            org: "mthines",             // …but this PR is in a DIFFERENT org with no rule
            role: .needsYourReview,
            config: cfg
        )
        assert(r4d == nil, "Focus rule scoped to one org must NOT mute PRs in an org with no rule")

        // --- Focus org lookup is case-insensitive ---
        let r4e = muteVerdict(
            title: "some PR",
            headRef: "branch",
            authorLogin: "dave",
            authorIsBot: false,
            requestedTeams: [],
            labels: [],
            org: "ACME",                // same org as the "acme" rule, different case
            role: .needsYourReview,
            config: cfg
        )
        if case .outsideFocus = r4e { } else { assertionFailure("Focus org lookup must be case-insensitive") }

        // --- Focus team match keeps a PR active (within its org) ---
        cfg = base
        cfg.focusByOrg = ["acme": OrgFocusConfig(authors: [], teams: ["ai"])]
        let r4f = muteVerdict(
            title: "some PR",
            headRef: "branch",
            authorLogin: "dash0-dev",
            authorIsBot: true,
            requestedTeams: ["ai"],     // requested via the focus team
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        assert(r4f == nil, "PR requested via a focus team must stay active")

        // --- Focus author match normalizes the `[bot]` suffix (mirrors Rule 2) ---
        // With muteBotAuthors OFF, a bot reaches Rule 4; a focus entry typed as
        // `dash0-dev[bot]` must still match the bare GraphQL login `dash0-dev`.
        cfg = base
        cfg.focusByOrg = ["acme": OrgFocusConfig(authors: ["dash0-dev[bot]"], teams: [])]
        let r4g = muteVerdict(
            title: "some PR",
            headRef: "branch",
            authorLogin: "dash0-dev",   // bare GraphQL login
            authorIsBot: true,
            requestedTeams: [],
            labels: [],
            org: "acme",
            role: .needsYourReview,
            config: cfg
        )
        assert(r4g == nil, "Focus author entered as `name[bot]` must match the bare bot login")
    }
    #endif
}
