import Foundation

// MARK: - MuteReason

/// The discriminated reason a PR was demoted to the Muted group.
/// First-match-wins: the engine walks the rules in order and returns the
/// first non-nil reason.
enum MuteReason {
    case pattern(String)   // matched a mutePatterns glob (the matching pattern)
    case botAuthor         // author is a bot and muteBotAuthors is on
    case label(String)     // carries a label in muteLabels (the matching label)
    case outsideFocus      // not in reviewFocusAuthors/Teams (Needs-your-review only)
}

// MARK: - InboxMuteConfig

/// Plain-value config built by the impure shell (PRManager) from MainlineSettings.
/// Passed to the pure engine so the engine has zero dependency on MainlineSettings.
struct InboxMuteConfig {
    var mutePatterns: [String]        // glob patterns for title/headRef (case-insensitive, * wildcard)
    var muteBotAuthors: Bool          // demote bot-authored PRs
    /// Bot logins that are exempt from `muteBotAuthors` — these bots are treated as
    /// active even when `muteBotAuthors` is ON. Case-insensitive. Uses the same login
    /// format as GitHub (e.g. "my-release-bot[bot]", "dependabot[bot]"). Empty = no
    /// exceptions; all detected bots are muted when `muteBotAuthors` is on.
    var botAllowList: [String]        // logins of bots that bypass the bot-author mute rule
    var reviewFocusAuthors: [String]  // allow-list of author logins (empty = disabled)
    var reviewFocusTeams: [String]    // allow-list of team slugs (empty = disabled)
    var muteLabels: [String]          // labels to demote (empty = disabled)
    var myLogin: String               // authenticated user's login (for role derivation)
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
    ///   4. Outside focus allow-list (Needs-your-review role only)
    static func muteVerdict(
        title: String,
        headRef: String,
        authorLogin: String,
        authorIsBot: Bool,
        requestedTeams: [String],
        labels: [String],
        role: InboxRole,
        config: InboxMuteConfig
    ) -> MuteReason? {
        // Rule 1 — title/branch pattern
        for pattern in config.mutePatterns where !pattern.isEmpty {
            if matches(text: title,   glob: pattern) { return .pattern(pattern) }
            if matches(text: headRef, glob: pattern) { return .pattern(pattern) }
        }

        // Rule 2 — bot author (skipped for logins in botAllowList)
        if config.muteBotAuthors {
            let isBotByEngine = authorIsBot || isBotLogin(authorLogin)
            if isBotByEngine {
                let allowed = config.botAllowList.contains {
                    $0.lowercased() == authorLogin.lowercased()
                }
                if !allowed { return .botAuthor }
            }
        }

        // Rule 3 — label
        if !config.muteLabels.isEmpty {
            for label in labels {
                if config.muteLabels.contains(where: { $0.lowercased() == label.lowercased() }) {
                    return .label(label)
                }
            }
        }

        // Rule 4 — outside focus (Needs-your-review only; never applies to Your PRs)
        if role == .needsYourReview {
            let focusEnabled = !config.reviewFocusAuthors.isEmpty || !config.reviewFocusTeams.isEmpty
            if focusEnabled {
                let authorInFocus = config.reviewFocusAuthors.contains(
                    where: { $0.lowercased() == authorLogin.lowercased() }
                )
                let teamInFocus = requestedTeams.contains { team in
                    config.reviewFocusTeams.contains(
                        where: { $0.lowercased() == team.lowercased() }
                    )
                }
                if !authorInFocus && !teamInFocus {
                    return .outsideFocus
                }
            }
        }

        return nil
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
            "dependabot", "renovate", "github-actions",
            "dependabot[bot]", "renovate[bot]", "github-actions[bot]"
        ]
        return knownBots.contains(lower)
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
            reviewFocusAuthors: [],
            reviewFocusTeams: [],
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
            role: .needsYourReview,
            config: cfg
        )
        if case .botAuthor = r2unlisted { } else { assertionFailure("Unlisted bot must still be muted when muteBotAuthors is on") }

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
            role: .needsYourReview,
            config: cfg
        )
        if case .label = r3 { } else { assertionFailure("Rule 3 (label) did not fire") }

        // --- Focus rule: outside focus → demote ---
        cfg = base
        cfg.reviewFocusAuthors = ["carol"]
        let r4 = muteVerdict(
            title: "some PR",
            headRef: "branch",
            authorLogin: "dave",    // not in focus list
            authorIsBot: false,
            requestedTeams: [],
            labels: [],
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
            role: .needsYourReview,
            config: cfg
        )
        assert(r4c == nil, "Focus rule must NOT fire for author in focus list")
    }
    #endif
}
