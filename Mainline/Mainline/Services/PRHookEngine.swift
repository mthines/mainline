import Foundation

/// A PR state change a hook can fire on. Raw values are what a template's `on:` line says.
enum HookTrigger: String, CaseIterable {
    case approved
    case changesRequested = "changes-requested"
    case ciFailed = "ci-failed"
    case ciPassed = "ci-passed"
    case conflict
    case readyToMerge = "ready-to-merge"
    case newComment = "new-comment"
    case reviewRequested = "review-requested"
    case readyForReview = "ready-for-review"
    case merged
    case closed

    /// One line per trigger for the New Hook starter's comments. Exhaustive, so a new trigger
    /// does not compile until it says what it means.
    var summary: String {
        switch self {
        case .approved: return "a reviewer approved"
        case .changesRequested: return "a reviewer requested changes"
        case .ciFailed: return "CI went red"
        case .ciPassed: return "CI went green"
        case .conflict: return "the PR got a merge conflict"
        case .readyToMerge: return "approved, green and mergeable"
        case .newComment: return "a human other than you commented or reviewed"
        case .reviewRequested: return "you or your team was asked to review (needs role: reviewing or any)"
        case .readyForReview: return "a draft was marked ready"
        case .merged: return "the PR merged"
        case .closed: return "the PR closed without merging"
        }
    }
}

struct HookEvent: Equatable {
    let trigger: HookTrigger
    let pr: PRSnapshot
}

/// A change to ONE named CI check on a PR (flag `check-hooks`). Kept apart from `HookTrigger`
/// so a hook on a check never changes how the rollup triggers (`ci-failed`) behave.
enum CheckHookTrigger: String, CaseIterable {
    case checkFailed = "check-failed"
    case checkPassed = "check-passed"

    var summary: String {
        switch self {
        case .checkFailed: return "the check named by `check:` failed (set `check:`)"
        case .checkPassed: return "the check named by `check:` passed (set `check:`)"
        }
    }
}

struct CheckHookEvent: Equatable {
    let trigger: CheckHookTrigger
    let pr: PRSnapshot
    /// The check's name as GitHub reports it.
    let check: String
}

/// Pure helpers for per-check data: the GraphQL selection, reducing a node to a `CheckState`,
/// and matching a hook's `check:` against a name. Never sent to telemetry (names are repo data).
enum CheckContexts {
    /// Checks fetched per PR. A PR with more reports only the first; the rest never fire (a check
    /// missing from a FULL previous page cannot fire), so truncation cannot cause a spurious event.
    static let pageSize = 50

    /// The head commit's oid, selected next to the rollup so a push is visible to `checkEvents`.
    static func commitSelection(enabled: Bool) -> String { enabled ? "oid " : "" }

    /// The selection nested in `statusCheckRollup`, or nothing while per-check data isn't wanted,
    /// so the query text with the flag off is exactly what it was.
    static func selection(enabled: Bool) -> String {
        guard enabled else { return "" }
        return """

                  contexts(first: \(pageSize)) {
                    nodes {
                      __typename
                      ... on CheckRun { name conclusion }
                      ... on StatusContext { context state }
                    }
                  }
        """
    }

    /// Whether to ask GitHub for per-check data: the flag is on and some hook names a check.
    static func wanted(flagOn: Bool, templates: [PromptTemplate]) -> Bool {
        flagOn && templates.contains(where: PRHookEngine.isCheckHook)
    }

    static func state(checkRunConclusion: String?) -> CheckState {
        switch checkRunConclusion?.uppercased() {
        case "SUCCESS": return .passed
        case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED": return .failed
        default: return .other   // in progress, cancelled, skipped, neutral, stale
        }
    }

    static func state(statusContext state: String?) -> CheckState {
        switch state?.uppercased() {
        case "SUCCESS": return .passed
        case "FAILURE", "ERROR": return .failed
        default: return .other   // pending, expected
        }
    }

    /// One result per name: a name reported twice (a re-run) is failed if either failed, passed only if all passed.
    static func merged(_ results: [CheckResult]) -> [CheckResult] {
        var order: [String] = []
        var byName: [String: CheckState] = [:]
        for r in results {
            guard !r.name.isEmpty else { continue }
            if let old = byName[r.name] {
                byName[r.name] = (old == .failed || r.state == .failed) ? .failed : (old == .passed && r.state == .passed ? .passed : .other)
            } else { order.append(r.name); byName[r.name] = r.state }
        }
        return order.map { CheckResult(name: $0, state: byName[$0] ?? .other) }
    }

    /// Case-insensitive exact match of `name` against `pattern`; `*` matches any run of characters.
    static func matches(pattern: String, name: String) -> Bool {
        let p = Array(pattern.trimmingCharacters(in: .whitespaces).lowercased())
        let n = Array(name.trimmingCharacters(in: .whitespaces).lowercased())
        guard !p.isEmpty else { return false }
        var memo: [Int: Bool] = [:]
        func go(_ i: Int, _ j: Int) -> Bool {
            let key = i * (n.count + 1) + j
            if let hit = memo[key] { return hit }
            let result: Bool
            if i == p.count { result = j == n.count }
            else if p[i] == "*" { result = go(i + 1, j) || (j < n.count && go(i, j + 1)) }
            else { result = j < n.count && p[i] == n[j] && go(i + 1, j + 1) }
            memo[key] = result
            return result
        }
        return go(0, 0)
    }
}

/// An issue change a hook can fire on: a template whose `for:` covers issues. Raw values are
/// what its `on:` line says; `new-comment` and `closed` share their spelling with the PR triggers,
/// so a `for: both` hook fires on either.
enum IssueHookTrigger: String, CaseIterable {
    case newIssue = "new-issue"
    case assigned
    case mentioned
    case newComment = "new-comment"
    case closed

    var summary: String {
        switch self {
        case .newIssue: return "a new issue in a repo watched at All issues (needs role: any)"
        case .assigned: return "an issue was assigned to you (needs role: any)"
        case .mentioned: return "you were newly @-mentioned on the issue (needs role: any)"
        case .newComment: return "a human other than you commented"
        case .closed: return "a followed issue was closed"
        }
    }
}

struct IssueHookEvent: Equatable {
    let trigger: IssueHookTrigger
    let issue: IssueSnapshot
}

/// Whose PRs a hook may fire on. Default `.authored`: an agent must not start by itself on
/// content a stranger wrote unless the hook says so.
enum HookRole: String {
    case authored, reviewing, any

    static func parse(_ text: String) -> HookRole { HookRole(rawValue: text.lowercased()) ?? .authored }
}

/// Pure hook logic: which events a poll produced, which templates they fire, and how often.
enum PRHookEngine {
    /// Events between two snapshot sets. An empty `previous` is a baseline (first poll): no events.
    /// A PR missing from a non-empty `previous` fires only `review-requested` (a PR you are asked to
    /// review first appears exactly that way); the carry-forward guard keeps incomplete fetches from
    /// making old PRs look new.
    static func events(previous: [String: PRSnapshot], next: [PRSnapshot], myLogin: String) -> [HookEvent] {
        guard !previous.isEmpty else { return [] }
        var out: [HookEvent] = []
        for pr in next {
            func add(_ t: HookTrigger) { out.append(HookEvent(trigger: t, pr: pr)) }
            guard let old = previous[pr.nodeId] else {
                if pr.tabs.contains(.forMe), pr.reviewRequestSource(myLogin: myLogin) != .none { add(.reviewRequested) }
                continue
            }

            if old.reviewDecision != .approved, pr.reviewDecision == .approved { add(.approved) }
            if old.reviewDecision != .changesRequested, pr.reviewDecision == .changesRequested { add(.changesRequested) }
            let failed: (CIStatus) -> Bool = { $0 == .failure || $0 == .error }
            if !failed(old.ciStatus), failed(pr.ciStatus) { add(.ciFailed) }
            if old.ciStatus != .success, pr.ciStatus == .success { add(.ciPassed) }
            // GitHub reports UNKNOWN (nil) while it recomputes after a push, so true → nil → false is the usual
        // path to a conflict; the throttle's cooldown bounds a CONFLICTING → UNKNOWN → CONFLICTING repeat.
        if old.mergeable != false, pr.mergeable == false { add(.conflict) }
            let oldTokens = PromptState.active(pr: old, myLogin: myLogin)
            if !oldTokens.contains("ready-to-merge"),
               PromptState.active(pr: pr, myLogin: myLogin).contains("ready-to-merge") { add(.readyToMerge) }
            let newComment = pr.commentCount > old.commentCount && !pr.lastCommentIsBot && !pr.lastCommentIsViewer
            let newReview = pr.reviewCount > old.reviewCount && !pr.lastReviewIsBot && !pr.lastReviewIsViewer
            if newComment || newReview { add(.newComment) }
            if pr.tabs.contains(.forMe), old.reviewRequestSource(myLogin: myLogin) == .none,
           pr.reviewRequestSource(myLogin: myLogin) != .none { add(.reviewRequested) }
            if old.isDraft, !pr.isDraft { add(.readyForReview) }
        }
        return out
    }

    /// Check events between two snapshot sets. A check absent from the previous snapshot fires only after a push,
    /// or on the same head when that snapshot was fetched with checks and its page was not full; otherwise never:
    /// an old persisted snapshot, a carried-forward PR, a PR fetched while the flag was off, or a check
    /// that only now fits in the fetched page all look like "new", and firing on them would re-notify
    /// every red check (the diff-baseline rule). Only an observed transition counts.
    static func checkEvents(previous: [String: PRSnapshot], next: [PRSnapshot]) -> [CheckHookEvent] {
        guard !previous.isEmpty else { return [] }
        var out: [CheckHookEvent] = []
        for pr in next where !pr.checkResults.isEmpty {
            guard let old = previous[pr.nodeId] else { continue }
            let before = Dictionary(old.checkResults.map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a })
            // A new head (a push) starts the checks over: what the new head reports is news even when
            // the same check failed on the old one, or finished before the next poll. Only when BOTH
            // snapshots carry results and a head, so an upgrade or a flag flip still fires nothing.
            let pushed = !old.checkResults.isEmpty && !old.headOid.isEmpty && !pr.headOid.isEmpty && old.headOid != pr.headOid
            // Same head, fetched with checks, previous page not full: a check missing before had not been
            // reported yet (queued late, or the rollup was still empty right after a push).
            let completeOnSameHead = !old.headOid.isEmpty && old.headOid == pr.headOid && old.checkResults.count < CheckContexts.pageSize
            for check in pr.checkResults {
                let was: CheckState
                if let seen = before[check.name] { was = pushed ? .other : seen }
                else if pushed || completeOnSameHead { was = .other } else { continue }
                if was != .failed, check.state == .failed {
                    out.append(CheckHookEvent(trigger: .checkFailed, pr: pr, check: check.name))
                }
                if was != .passed, check.state == .passed {
                    out.append(CheckHookEvent(trigger: .checkPassed, pr: pr, check: check.name))
                }
            }
        }
        return out
    }

    /// `merged` / `closed` events from the display-only Done set, which open-PR polls never see.
    /// Only a PR this app saw OPEN (`seenOpen`) can fire: the Done set is just the 30 most recently
    /// updated finished PRs, so an old one nudged back into it by a late comment is not news.
    /// `fired` accumulates so a PR never fires twice.
    static func doneEvents(seenOpen: Set<String>, fired: Set<String>, done: [PRSnapshot]) -> (events: [HookEvent], fired: Set<String>) {
        let events = done.filter { seenOpen.contains($0.nodeId) && !fired.contains($0.nodeId) }.compactMap { pr -> HookEvent? in
            if pr.merged { return HookEvent(trigger: .merged, pr: pr) }
            if pr.closed { return HookEvent(trigger: .closed, pr: pr) }
            return nil
        }
        return (events, fired.union(events.map(\.pr.nodeId)))
    }

    /// `on: ci-failed, approved` → triggers + the words that are not triggers.
    static func parseTriggers(_ text: String) -> (triggers: [HookTrigger], unknown: [String]) { parse(text) }

    /// `on: assigned, closed` → issue triggers + the words that are not issue triggers.
    static func parseIssueTriggers(_ text: String) -> (triggers: [IssueHookTrigger], unknown: [String]) { parse(text) }

    private static func parse<T: RawRepresentable & Equatable>(_ text: String) -> (triggers: [T], unknown: [String])
    where T.RawValue == String {
        var triggers: [T] = [], unknown: [String] = []
        for word in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !word.isEmpty {
            if let t = T(rawValue: word) { if !triggers.contains(t) { triggers.append(t) } } else { unknown.append(word) }
        }
        return (triggers, unknown)
    }

    /// `on: check-failed` → check triggers + the words that are not check triggers.
    static func parseCheckTriggers(_ text: String) -> (triggers: [CheckHookTrigger], unknown: [String]) { parse(text) }

    /// A hook on a named check: PR subject, a check trigger, and the `check:` it watches.
    static func isCheckHook(_ t: PromptTemplate) -> Bool {
        t.subject.covers(.prs) && !parseCheckTriggers(t.on).triggers.isEmpty
            && !t.hookCheck.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A check trigger with no `check:` can never fire; Settings shows this.
    static func checkHookMissingName(_ t: PromptTemplate) -> Bool {
        t.subject.covers(.prs) && !parseCheckTriggers(t.on).triggers.isEmpty
            && t.hookCheck.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func isHook(_ t: PromptTemplate) -> Bool { t.subject.covers(.prs) && !parseTriggers(t.on).triggers.isEmpty }

    static func isIssueHook(_ t: PromptTemplate) -> Bool {
        t.subject.covers(.issues) && !parseIssueTriggers(t.on).triggers.isEmpty
    }

    /// The `on:` words that are a trigger for none of the subjects the template's `for:` covers.
    /// `issues` says whether issue triggers are live (flag `issue-hooks`): while off, they are unknown.
    /// `checks` says whether check triggers are live (flag `check-hooks`): while off, they are unknown.
    static func unknownTriggers(_ t: PromptTemplate, issues: Bool, checks: Bool = false) -> [String] {
        let words = t.on.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return words.filter { word in
            guard !word.isEmpty else { return false }
            let pr = t.subject.covers(.prs) && HookTrigger(rawValue: word) != nil
            let issue = issues && t.subject.covers(.issues) && IssueHookTrigger(rawValue: word) != nil
            let check = checks && t.subject.covers(.prs) && CheckHookTrigger(rawValue: word) != nil
            return !pr && !issue && !check
        }
    }

    /// Issue-hook events from one issue poll. `transitions` is that poll's `IssueDiffEngine.diff`
    /// (so watch levels, seeding and the new-issue age limit already apply); `closed` are the
    /// issues that left the followed set and GitHub reports CLOSED. The caller suppresses a
    /// launch's first poll (its baseline is from the last run).
    static func issueEvents(previous: [String: IssueSnapshot], next: [IssueSnapshot],
                            transitions: [IssueTransition], closed: [IssueSnapshot],
                            myLogin: String) -> [IssueHookEvent] {
        guard !myLogin.isEmpty else { return [] }
        var out: [IssueHookEvent] = transitions.compactMap {
            switch $0 {
            case .newIssue(let i): return IssueHookEvent(trigger: .newIssue, issue: i)
            case .assigned(let i): return IssueHookEvent(trigger: .assigned, issue: i)
            case .mentioned(let i): return IssueHookEvent(trigger: .mentioned, issue: i)
            case .reply: return nil   // covered by new-comment below, which also sees other people's issues
            }
        }
        for issue in next {
            guard let old = previous[issue.nodeId], issue.commentCount > old.commentCount else { continue }
            // Every comment added since the last poll (as far as the fetched tail reaches), not just
            // the newest: Bob's comment still counts when you or a bot replied before the next poll.
            let added = issue.comments.suffix(issue.commentCount - old.commentCount)
            guard added.contains(where: { !PRSnapshot.loginsMatch($0.author, myLogin) && !$0.isBot }) else { continue }
            out.append(IssueHookEvent(trigger: .newComment, issue: issue))
        }
        out += closed.filter { previous[$0.nodeId] != nil }.map { IssueHookEvent(trigger: .closed, issue: $0) }
        return out
    }

    /// Issues in `previous` that a complete poll no longer returns, outside Off repos: the
    /// candidates for `closed` (they may instead have been unassigned; the caller asks GitHub).
    static func leftIssues(previous: [String: IssueSnapshot], next: [IssueSnapshot],
                           watchLevel: (String) -> IssueWatchLevel) -> [IssueSnapshot] {
        let have = Set(next.map(\.nodeId))
        return previous.values.filter { !have.contains($0.nodeId) && watchLevel($0.repoFullName) != .off }
            .sorted { $0.nodeId < $1.nodeId }
    }

    /// Whether `template` fires for an issue event: subject, trigger, repo scope, then role.
    /// `role: authored` (default) = you opened the issue; `any` opts in to other people's
    /// content; `reviewing` never matches an issue. `when:` guards are PR-only, so an issue
    /// hook that has one never fires rather than firing more often than written.
    static func matches(_ t: PromptTemplate, issueEvent event: IssueHookEvent, myLogin: String) -> Bool {
        guard t.subject.covers(.issues), parseIssueTriggers(t.on).triggers.contains(event.trigger) else { return false }
        let scopes = CommentEngine.parseScope(t.hookScope)
        guard scopes.isEmpty || scopes.contains(where: { CommentEngine.patternMatches($0, repo: event.issue.repoFullName) })
        else { return false }
        switch HookRole.parse(t.hookRole) {
        case .authored: guard event.issue.isAuthored(by: myLogin) else { return false }
        case .reviewing: return false
        case .any: break
        }
        guard t.when.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // A `for: both` hook written for PRs (`{{pr.*}}`) cannot render for an issue: skip it here,
        // before the countdown and the throttle, rather than fail after both.
        return (try? PromptEngine.renderBody(t, context: PromptTarget(issues: [event.issue]).context)) != nil
    }

    /// Whether an issue hook's prompt can be filled for an issue. `matches` skips one that can't
    /// (a `{{pr.*}}` body), so Settings uses this to warn that it will never fire on an issue.
    static func issueBodyRenders(_ t: PromptTemplate) -> Bool {
        let sample = IssueSnapshot(nodeId: "sample", number: 1, title: "t", url: "u", repoFullName: "o/r", author: "a",
                                   createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        return (try? PromptEngine.renderBody(t, context: PromptTarget(issues: [sample]).context)) != nil
    }

    /// The PR-side mirror of `issueBodyRenders`, for a `for: both` hook: `matches` skips a PR event
    /// whose prompt can't be filled (an `{{issue.*}}` body), so Settings warns it never fires on a PR.
    static func prBodyRenders(_ t: PromptTemplate) -> Bool {
        let sample = PRSnapshot(
            nodeId: "sample", number: 1, title: "t", htmlUrl: "u", repoFullName: "o/r", isDraft: false, state: "open",
            reviewDecision: nil, ciStatus: .pending, reviewState: .none, commentCount: 0, updatedAt: "",
            author: "a", requestedReviewers: [], mergeable: true)
        let context = PromptTarget(anchor: sample, members: [sample], wholeStack: false).context
        return (try? PromptEngine.renderBody(t, context: context)) != nil
    }

    /// The (hook, event) pairs one issue poll launches: every match, but at most ONE per hook per
    /// issue. A comment that first @-mentions you yields both `mentioned` and `new-comment`, and the
    /// throttle keys them apart, so without this a hook on both starts two agents for one comment.
    /// The first event wins (`issueEvents` lists transitions, so `mentioned`, before `new-comment`).
    static func issueLaunches(_ hooks: [PromptTemplate], events: [IssueHookEvent],
                              myLogin: String) -> [(hook: PromptTemplate, event: IssueHookEvent)] {
        var seen = Set<String>()
        return events.flatMap { event in
            hooks.filter { matches($0, issueEvent: event, myLogin: myLogin) }.map { (hook: $0, event: event) }
        }.filter { seen.insert("\($0.hook.fileName)|\($0.event.issue.nodeId)").inserted }
    }

    /// Whether `template` fires for `event`: trigger, repo scope, role, then the `when:` guard.
    static func matches(_ t: PromptTemplate, event: HookEvent, myLogin: String) -> Bool {
        guard parseTriggers(t.on).triggers.contains(event.trigger) else { return false }
        return passesFilters(t, pr: event.pr, myLogin: myLogin)
    }

    /// Whether `template` fires for a check event: a check trigger, the named check, then the same
    /// scope / role / `when:` filters as every PR hook.
    static func matches(_ t: PromptTemplate, checkEvent event: CheckHookEvent, myLogin: String) -> Bool {
        guard t.subject.covers(.prs), parseCheckTriggers(t.on).triggers.contains(event.trigger),
              CheckContexts.matches(pattern: t.hookCheck, name: event.check) else { return false }
        return passesFilters(t, pr: event.pr, myLogin: myLogin)
    }

    /// The filters every PR hook shares once its trigger matched: repo scope, role, `when:`, and the
    /// `for: both` render guard.
    private static func passesFilters(_ t: PromptTemplate, pr: PRSnapshot, myLogin: String) -> Bool {
        let repo = pr.repoFullName
        let scopes = CommentEngine.parseScope(t.hookScope)
        guard scopes.isEmpty || scopes.contains(where: { CommentEngine.patternMatches($0, repo: repo) }) else { return false }
        let state = PromptState.active(pr: pr, myLogin: myLogin)
        switch HookRole.parse(t.hookRole) {
        // `authored` means YOU opened it. `PromptState`'s `authored` token also covers a PR you merely
        // committed to, and commit authorship (a `Co-authored-by:` trailer, an email) is forgeable by a
        // stranger — so a hook never trusts it. `role: any` is the explicit opt-in.
        case .authored: guard PRSnapshot.loginsMatch(pr.author, myLogin) else { return false }
        case .reviewing: guard state.contains("reviewing") else { return false }
        case .any: break
        }
        if !t.when.trimmingCharacters(in: .whitespaces).isEmpty,
           PromptState.matchedAlternative(t.when, active: state) == nil { return false }
        // The mirror of the issue side: a `for: both` hook written for issues (`{{issue.*}}`) cannot
        // render for a PR, so skip it before the countdown and the throttle. A PR-only hook is not
        // checked, so a broken one still fails visibly ("Hook failed").
        guard t.subject.covers(.issues) else { return true }
        let context = PromptTarget(anchor: pr, members: [pr], wholeStack: false).context
        return (try? PromptEngine.renderBody(t, context: context)) != nil
    }

    /// Per-PR-per-hook-per-trigger cooldown plus a global hourly cap, so a flapping check or a
    /// bad hook can't start agent after agent. Value type; `now` is passed in.
    struct Throttle {
        var cooldown: TimeInterval = 30 * 60
        var hourlyCap = 10
        private(set) var lastFired: [String: Date] = [:]
        private(set) var launches: [Date] = []

        static func key(_ hook: String, _ event: HookEvent) -> String { "\(hook)|\(event.trigger.rawValue)|\(event.pr.nodeId)" }
        /// The check's name is part of the key, so two checks failing on one PR launch separately.
        static func key(_ hook: String, _ event: CheckHookEvent) -> String {
            "\(hook)|check:\(event.trigger.rawValue):\(event.check.lowercased())|\(event.pr.nodeId)"
        }
        static func key(_ hook: String, _ event: IssueHookEvent) -> String {
            "\(hook)|issue:\(event.trigger.rawValue)|\(event.issue.nodeId)"
        }

        /// Records and returns true when the launch is allowed.
        mutating func admit(key: String, now: Date) -> Bool {
            launches.removeAll { now.timeIntervalSince($0) > 3600 }
            if let last = lastFired[key], now.timeIntervalSince(last) < cooldown { return false }
            guard launches.count < hourlyCap else { return false }
            lastFired[key] = now
            launches.append(now)
            return true
        }
    }
}

extension PRHookEngine {
    /// The commented-out frontmatter a New Hook starts with: the activation lines, then every
    /// option and trigger, so the file explains itself without the README. Lines start with `#`,
    /// which the frontmatter parser skips.
    static var starterFrontmatter: String { starterFrontmatter(issues: false, checks: false) }

    /// `issues` (flag `issue-hooks`) adds the issue triggers and how `for:` / `role:` apply to them.
    static func starterFrontmatter(issues: Bool, checks: Bool = false) -> String {
        let all = HookTrigger.allCases.map { ($0.rawValue, $0.summary) }
        let issueTriggers = IssueHookTrigger.allCases.map { ($0.rawValue, $0.summary) }
        let checkTriggers = CheckHookTrigger.allCases.map { ($0.rawValue, $0.summary) }
        let width = (all + (issues ? issueTriggers : []) + (checks ? checkTriggers : [])).map(\.0.count).max() ?? 0
        func lines(_ list: [(String, String)]) -> [String] {
            list.map { "#   \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
        }
        let issueBlock = issues ? [
            "#",
            "# Issue triggers (set `for: issues`, or `for: both` for PRs and issues; use {{issue.*}}):",
            "#   The prompt below uses {{pr.*}}: rewrite it with {{issue.url}} etc., or it never fires on an issue.",
        ] + lines(issueTriggers) + [
            "#   On issues, role: authored = you opened it, any = anyone; reviewing never matches,",
            "#   and an issue hook with `when:` never fires.",
        ] : []
        let checkBlock = checks ? [
            "#",
            "# Check triggers: also set `check:` to ONE check name (a GitHub Actions job or commit status),",
            "# case-insensitive, `*` matches any run of characters. A name with commas is fine here.",
            "# check: build (ubuntu, 20)",
        ] + lines(checkTriggers) : []
        return ([
            "# Uncomment `on:` (and narrow `scope:`) to activate:",
            "# on: ci-failed",
            "# scope: owner/repo",
            "#",
            "# on:    one or more triggers, comma-separated",
        ] + lines(all) + issueBlock + checkBlock + [
            "# scope: owner/repo, owner/*, or * (default: every repo)",
            "# role:  authored (default) | reviewing | any",
            "# when:  optional state guard, e.g. !conflict (see README.txt)",
        ]).joined(separator: "\n") + "\n"
    }
}

#if DEBUG
enum PRHookChecks {
    static func run() {
        for t in HookTrigger.allCases {
            assert(PRHookEngine.starterFrontmatter.contains("#   \(t.rawValue) "), "starter lists \(t.rawValue)")
        }
        assert(PRHookEngine.starterFrontmatter.split(separator: "\n").allSatisfy { $0.hasPrefix("#") },
               "starter frontmatter is all comments")
        func pr(_ id: String = "n1", ci: CIStatus = .pending, decision: ReviewDecision? = nil, mergeable: Bool? = true,
                draft: Bool = false, author: String = "me") -> PRSnapshot {
            PRSnapshot(
                nodeId: id, number: 1, title: "t", htmlUrl: "u", repoFullName: "o/r", isDraft: draft, state: "open",
                reviewDecision: decision, ciStatus: ci, reviewState: .none, commentCount: 0, updatedAt: "",
                author: author, requestedReviewers: [], mergeable: mergeable)
        }
        func triggers(_ a: PRSnapshot, _ b: PRSnapshot) -> Set<HookTrigger> {
            Set(PRHookEngine.events(previous: [a.nodeId: a], next: [b], myLogin: "me").map(\.trigger))
        }
        assert(PRHookEngine.events(previous: [:], next: [pr()], myLogin: "me").isEmpty, "empty previous is a baseline, not an event")
        var asked = pr("n2", author: "them"); asked.tabs = [.forMe]; asked.requestedReviewers = ["me"]
        assert(PRHookEngine.events(previous: ["n1": pr()], next: [asked], myLogin: "me").map(\.trigger) == [.reviewRequested],
               "a new PR already asking for you fires review-requested")
        assert(PRHookEngine.events(previous: ["n1": pr()], next: [pr("n3")], myLogin: "me").isEmpty, "other new PRs fire nothing")
        assert(triggers(pr(), pr(decision: .approved)) == [.approved], "approved")
        assert(triggers(pr(decision: .approved), pr(decision: .approved)).isEmpty, "steady state fires nothing")
        assert(triggers(pr(), pr(ci: .failure)).contains(.ciFailed), "ci-failed")
        assert(triggers(pr(ci: .failure), pr(ci: .error)).isEmpty, "failure → error is not a new failure")
        assert(triggers(pr(), pr(ci: .success)).contains(.ciPassed), "ci-passed")
        assert(triggers(pr(), pr(mergeable: false)).contains(.conflict), "conflict")
        assert(triggers(pr(mergeable: nil), pr(mergeable: false)).contains(.conflict), "UNKNOWN → conflicting still fires")
        assert(triggers(pr(mergeable: false), pr(mergeable: false)).isEmpty, "still conflicting fires nothing")
        assert(triggers(pr(draft: true), pr()).contains(.readyForReview), "draft → ready")
        var req = pr(); req.tabs = [.forMe]; req.requestedReviewers = ["me"]
        assert(triggers(pr(), req) == [.reviewRequested], "a review request on a tracked PR")
        var held = req; held.tabs = []
        assert(triggers(held, req).isEmpty, "regaining the For me tab after a partial poll is not a new request")
        var mine = pr(); mine.commentCount = 1; mine.lastCommentIsViewer = true
        var theirs = pr(); theirs.commentCount = 1
        assert(triggers(pr(), mine).isEmpty, "your own comment fires no new-comment")
        assert(triggers(pr(), theirs) == [.newComment], "someone else's comment does")

        let t = PRHookEngine.parseTriggers("ci-failed, Approved, nope")
        assert(t.triggers == [.ciFailed, .approved] && t.unknown == ["nope"], "parseTriggers")

        var hook = PromptTemplate(fileName: "h.md", name: "h", harness: "claude", checkout: false, body: "x")
        hook.on = "approved"
        let ev = HookEvent(trigger: .approved, pr: pr())
        assert(PRHookEngine.matches(hook, event: ev, myLogin: "me"), "authored PR matches by default")
        assert(!PRHookEngine.matches(hook, event: HookEvent(trigger: .approved, pr: pr(author: "them")), myLogin: "me"),
               "someone else's PR needs role: reviewing/any")
        var committed = pr(author: "them"); committed.viewerIsCommitter = true
        assert(!PRHookEngine.matches(hook, event: HookEvent(trigger: .approved, pr: committed), myLogin: "me"),
               "a forgeable committer link is not authorship")
        hook.hookRole = "any"
        assert(PRHookEngine.matches(hook, event: HookEvent(trigger: .approved, pr: pr(author: "them")), myLogin: "me"), "role any")
        assert(!PRHookEngine.matches(hook, event: HookEvent(trigger: .ciFailed, pr: pr()), myLogin: "me"), "wrong trigger")
        hook.when = "conflict"
        assert(!PRHookEngine.matches(hook, event: ev, myLogin: "me"), "when: guard")

        var both = PromptTemplate(fileName: "b.md", name: "b", harness: "claude", checkout: false, body: "Look at {{issue.url}}")
        both.subject = .both; both.on = "approved"
        assert(!PRHookEngine.matches(both, event: ev, myLogin: "me"), "a for: both {{issue.*}} body never fires on a PR")
        assert(!PRHookEngine.prBodyRenders(both), "Settings warns about an {{issue.*}} body on a for: both hook")
        both.body = "Look at {{pr.url}}"
        assert(PRHookEngine.matches(both, event: ev, myLogin: "me"), "a for: both {{pr.*}} body does")
        assert(PRHookEngine.prBodyRenders(both), "no warning for a {{pr.*}} body")

        func done(_ id: String, merged: Bool) -> PRSnapshot {
            var p = pr(id); p.merged = merged; p.closed = !merged; p.state = "closed"; return p
        }
        let all = [done("a", merged: true), done("b", merged: true), done("c", merged: false)]
        let first = PRHookEngine.doneEvents(seenOpen: ["b", "c"], fired: [], done: all)
        assert(first.events.map(\.trigger) == [.merged, .closed], "Done PRs seen open fire merged / closed")
        assert(!first.events.contains { $0.pr.nodeId == "a" }, "a PR never seen open (old, resurfaced) fires nothing")
        assert(PRHookEngine.doneEvents(seenOpen: ["b", "c"], fired: first.fired, done: all).events.isEmpty, "no repeat")

        var th = PRHookEngine.Throttle(cooldown: 60, hourlyCap: 2)
        let t0 = Date()
        assert(th.admit(key: "a", now: t0), "first launch")
        assert(!th.admit(key: "a", now: t0.addingTimeInterval(10)), "cooldown")
        assert(th.admit(key: "b", now: t0.addingTimeInterval(10)), "other key")
        assert(!th.admit(key: "c", now: t0.addingTimeInterval(20)), "hourly cap")
        assert(th.admit(key: "c", now: t0.addingTimeInterval(3700)), "cap window expires")
    }
}
enum IssueHookChecks {
    static func run() {
        let me = "mads"
        func issue(_ id: String = "i1", author: String = "alice", comments: [IssueReply] = [],
                   repo: String = "acme/app") -> IssueSnapshot {
            IssueSnapshot(nodeId: id, number: 1, title: "t", url: "u", repoFullName: repo, author: author,
                          createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                          commentCount: comments.count, comments: comments)
        }
        func reply(_ by: String, bot: Bool = false) -> IssueReply {
            IssueReply(author: by, createdAt: Date(), association: "NONE", isBot: bot)
        }
        func triggers(_ prev: [IssueSnapshot], _ next: [IssueSnapshot], _ tr: [IssueTransition] = [],
                      closed: [IssueSnapshot] = []) -> [IssueHookTrigger] {
            PRHookEngine.issueEvents(previous: Dictionary(uniqueKeysWithValues: prev.map { ($0.nodeId, $0) }),
                                     next: next, transitions: tr, closed: closed, myLogin: me).map(\.trigger)
        }

        let a = issue()
        assert(triggers([], [a], [.assigned(a)]) == [.assigned], "with nothing followed before, a transition still fires")
        assert(triggers([a], [a, issue("i2")], [.newIssue(issue("i2"))]) == [.newIssue], "new-issue")
        assert(triggers([a], [a], [.assigned(a)]) == [.assigned], "assigned")
        assert(triggers([a], [a], [.mentioned(a)]) == [.mentioned], "mentioned")
        assert(triggers([a], [a], [.reply(a)]).isEmpty, "reply maps to new-comment only through the comment diff")
        assert(triggers([a], [a]).isEmpty, "an unchanged issue fires nothing")
        assert(triggers([a], [issue(comments: [reply("bob")])]) == [.newComment], "someone else's comment")
        assert(triggers([a], [issue(comments: [reply("Mads")])]).isEmpty, "your own comment fires nothing")
        assert(triggers([a], [issue(comments: [reply("github-actions", bot: true)])]).isEmpty, "a bot comment fires nothing")
        assert(triggers([a], [issue(comments: [reply("bob"), reply("mads")])]) == [.newComment],
               "someone's comment counts even when yours came after it in the same poll")
        let seen = issue(comments: [reply("bob")])
        assert(triggers([seen], [issue(comments: [reply("bob"), reply("mads")])]).isEmpty,
               "an already-seen comment does not fire again behind your new one")
        assert(triggers([], [issue(comments: [reply("bob")])]).isEmpty, "a first-seen issue's comments are not new")
        assert(triggers([a], [], closed: [a]) == [.closed], "closed")
        assert(triggers([a], [], closed: [issue("x")]).isEmpty, "closed only for an issue this app followed")
        assert(PRHookEngine.issueEvents(previous: ["i1": a], next: [a], transitions: [.assigned(a)], closed: [],
                                        myLogin: "").isEmpty, "no identity, no events")

        let left = PRHookEngine.leftIssues(previous: ["i1": a, "i2": issue("i2", repo: "acme/off")], next: [],
                                           watchLevel: { $0 == "acme/off" ? .off : .onlyMine })
        assert(left.map(\.nodeId) == ["i1"], "an issue in a repo turned Off is not a close candidate")
        assert(PRHookEngine.leftIssues(previous: ["i1": a], next: [a], watchLevel: { _ in .allIssues }).isEmpty,
               "an issue still followed did not leave")

        var hook = PromptTemplate(fileName: "h.md", name: "h", harness: "claude", checkout: false, body: "x")
        hook.on = "assigned, mentioned"
        let mine = IssueHookEvent(trigger: .mentioned, issue: issue(author: "Mads"))
        let theirs = IssueHookEvent(trigger: .assigned, issue: a)
        assert(!PRHookEngine.isIssueHook(hook) && !PRHookEngine.matches(hook, issueEvent: mine, myLogin: me),
               "a PR template (default for: prs) never fires on an issue")
        assert(PRHookEngine.isHook(hook) == false, "issue-only words do not make a PR hook")
        hook.subject = .issues
        assert(PRHookEngine.isIssueHook(hook) && !PRHookEngine.isHook(hook), "for: issues is an issue hook only")
        assert(PRHookEngine.matches(hook, issueEvent: mine, myLogin: me), "your own issue matches by default")
        assert(!PRHookEngine.matches(hook, issueEvent: theirs, myLogin: me), "a stranger's issue needs role: any")
        assert(!PRHookEngine.matches(hook, issueEvent: IssueHookEvent(trigger: .newIssue, issue: issue(author: "mads")),
                                     myLogin: me), "wrong trigger")
        hook.hookRole = "reviewing"
        assert(!PRHookEngine.matches(hook, issueEvent: mine, myLogin: me), "reviewing never matches an issue")
        hook.hookRole = "any"
        assert(PRHookEngine.matches(hook, issueEvent: theirs, myLogin: me), "role: any")
        hook.hookScope = "acme/other"
        assert(!PRHookEngine.matches(hook, issueEvent: theirs, myLogin: me), "scope")
        hook.hookScope = "acme/*"
        assert(PRHookEngine.matches(hook, issueEvent: theirs, myLogin: me), "org scope")
        hook.when = "conflict"
        assert(!PRHookEngine.matches(hook, issueEvent: theirs, myLogin: me), "an issue hook with when: never fires")

        var both = PromptTemplate(fileName: "b.md", name: "b", harness: "claude", checkout: false, body: "x")
        both.subject = .both; both.on = "closed, approved, nope"
        assert(PRHookEngine.isHook(both) && PRHookEngine.isIssueHook(both), "for: both is a hook on either")
        assert(PRHookEngine.unknownTriggers(both, issues: true) == ["nope"], "unknown words for for: both")
        both.hookRole = "any"
        let closedIssue = IssueHookEvent(trigger: .closed, issue: a)
        both.body = "Look at {{pr.url}}"
        assert(!PRHookEngine.matches(both, issueEvent: closedIssue, myLogin: me), "a {{pr.*}} body never fires on an issue")
        assert(!PRHookEngine.issueBodyRenders(both), "Settings warns about a {{pr.*}} body on an issue hook")
        both.body = "Look at {{issue.url}}"
        assert(PRHookEngine.matches(both, issueEvent: closedIssue, myLogin: me), "an {{issue.*}} body does")
        assert(PRHookEngine.issueBodyRenders(both), "no warning for an {{issue.*}} body")
        var issuesOnly = both; issuesOnly.subject = .issues
        assert(PRHookEngine.unknownTriggers(issuesOnly, issues: true) == ["approved", "nope"],
               "a PR trigger is unknown on a for: issues hook")
        assert(PRHookEngine.unknownTriggers(issuesOnly, issues: false) == ["closed", "approved", "nope"],
               "with issue hooks off, issue triggers are unknown")

        assert(PRHookEngine.Throttle.key("h", theirs) != PRHookEngine.Throttle.key("h", IssueHookEvent(trigger: .closed, issue: a)),
               "throttle keys differ per trigger")

        var onBoth = PromptTemplate(fileName: "m.md", name: "m", harness: "claude", checkout: false, body: "{{issue.url}}")
        onBoth.subject = .issues; onBoth.on = "mentioned, new-comment"; onBoth.hookRole = "any"
        let commented = issue(comments: [reply("bob")])
        let mentionEvents = PRHookEngine.issueEvents(previous: ["i1": a], next: [commented], transitions: [.mentioned(commented)],
                                                     closed: [], myLogin: me)
        assert(mentionEvents.map(\.trigger) == [.mentioned, .newComment], "a mentioning comment yields both, mentioned first")
        let launched = PRHookEngine.issueLaunches([onBoth], events: mentionEvents, myLogin: me)
        assert(launched.map(\.event.trigger) == [.mentioned], "one comment launches a hook once, as mentioned")
        var other = onBoth; other.fileName = "o.md"
        assert(PRHookEngine.issueLaunches([onBoth, other], events: mentionEvents, myLogin: me).count == 2,
               "each hook still launches once")
        let starter = PRHookEngine.starterFrontmatter(issues: true)
        for t in IssueHookTrigger.allCases { assert(starter.contains("#   \(t.rawValue) "), "starter lists \(t.rawValue)") }
        assert(!PRHookEngine.starterFrontmatter.contains("new-issue"), "flag off: no issue triggers in the starter")
        assert(starter.split(separator: "\n").allSatisfy { $0.hasPrefix("#") }, "issue starter is all comments")
    }
}

/// Self-checks for hooks on one named CI check. Each section prints a `CHECK HOOK <name> OK` line
/// once its assertions hold; the sealed checks in `.agent/feat/check-hooks/checks.yaml` read them.
enum CheckHookChecks {
    static func run() {
        func pr(_ id: String = "n1", checks: [CheckResult] = []) -> PRSnapshot {
            PRSnapshot(
                nodeId: id, number: 1, title: "t", htmlUrl: "u", repoFullName: "o/r", isDraft: false, state: "open",
                reviewDecision: nil, ciStatus: .pending, reviewState: .none, commentCount: 0, updatedAt: "",
                author: "me", requestedReviewers: [], mergeable: true, checkResults: checks)
        }
        func c(_ name: String, _ state: CheckState) -> CheckResult { CheckResult(name: name, state: state) }
        func events(_ a: PRSnapshot, _ b: PRSnapshot) -> [CheckHookEvent] {
            PRHookEngine.checkEvents(previous: [a.nodeId: a], next: [b])
        }
        func hook(on: String = "check-failed", check: String = "X") -> PromptTemplate {
            var t = PromptTemplate(fileName: "h.md", name: "h", harness: "claude", checkout: false, body: "Fix {{pr.url}}")
            t.on = on; t.hookCheck = check
            return t
        }

        // AC-1: the named check failing matches; another failing check does not.
        let failedX = events(pr(checks: [c("X", .passed), c("Y", .passed)]), pr(checks: [c("X", .failed), c("Y", .passed)]))
        assert(failedX.map(\.trigger) == [.checkFailed] && failedX.map(\.check) == ["X"], "X failing is one check-failed event")
        assert(PRHookEngine.matches(hook(), checkEvent: failedX[0], myLogin: "me"), "the hook for X matches X failing")
        let failedY = events(pr(checks: [c("X", .passed), c("Y", .passed)]), pr(checks: [c("X", .passed), c("Y", .failed)]))
        assert(!PRHookEngine.matches(hook(), checkEvent: failedY[0], myLogin: "me"), "Y failing does not match a hook for X")
        assert(events(pr(checks: [c("X", .failed)]), pr(checks: [c("X", .failed)])).isEmpty, "still failing fires nothing")
        assert(events(pr(checks: [c("X", .other)]), pr(checks: [c("X", .failed)])).count == 1, "running → failed fires")
        print("CHECK HOOK named-failed OK")

        // AC-2: passing is symmetric.
        let passedX = events(pr(checks: [c("X", .failed)]), pr(checks: [c("X", .passed)]))
        assert(passedX.map(\.trigger) == [.checkPassed], "failed → passed is check-passed")
        assert(PRHookEngine.matches(hook(on: "check-passed"), checkEvent: passedX[0], myLogin: "me"), "check-passed hook matches")
        assert(!PRHookEngine.matches(hook(on: "check-failed"), checkEvent: passedX[0], myLogin: "me"), "check-failed hook ignores a pass")
        assert(events(pr(checks: [c("X", .passed)]), pr(checks: [c("X", .passed)])).isEmpty, "steady pass fires nothing")
        print("CHECK HOOK named-passed OK")

        // AC-3: `check:` parses, serializes, and matches names with commas, colons and spaces.
        let raw = PromptEngine.serialize(hook(check: "build (ubuntu, 20): unit"))
        let back = PromptEngine.parse(fileName: "h.md", text: raw)
        assert(back?.hookCheck == "build (ubuntu, 20): unit", "check: survives a round trip with , : and spaces")
        assert(back?.on == "check-failed", "on: survives alongside check:")
        assert(CheckContexts.matches(pattern: "Build (Ubuntu, 20)", name: "build (ubuntu, 20)"), "case-insensitive")
        assert(!CheckContexts.matches(pattern: "build", name: "build (ubuntu, 20)"), "exact, not a prefix")
        assert(CheckContexts.matches(pattern: "build*", name: "build (ubuntu, 20)"), "* wildcard")
        assert(CheckContexts.matches(pattern: "*unit", name: "ci / unit"), "leading wildcard")
        assert(!CheckContexts.matches(pattern: "", name: "x"), "empty pattern matches nothing")
        assert(PRHookEngine.checkHookMissingName(hook(check: "")) && !PRHookEngine.isCheckHook(hook(check: "")),
               "a check trigger with no check: is flagged and never a hook")
        print("CHECK HOOK check-field OK")

        // AC-4: a check missing from the previous snapshot never fires.
        assert(events(pr(), pr(checks: [c("X", .failed)])).isEmpty, "previous snapshot had no checks (upgrade, flag was off)")
        assert(events(pr(checks: [c("Y", .passed)]), pr(checks: [c("X", .failed)])).isEmpty, "X absent before")
        assert(PRHookEngine.checkEvents(previous: [:], next: [pr(checks: [c("X", .failed)])]).isEmpty, "first poll is a baseline")
        assert(PRHookEngine.checkEvents(previous: ["n1": pr(checks: [c("X", .passed)])], next: [pr("n2", checks: [c("X", .failed)])]).isEmpty,
               "a PR new to the baseline fires nothing")
        assert(events(pr(checks: [c("X", .passed)]), pr()).isEmpty, "a poll fetched without checks fires nothing")
        let old = pr(checks: [c("X", .passed)])
        let data = try! JSONEncoder().encode(old)
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "checkResults")
        let decoded = try! JSONDecoder().decode(PRSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        assert(decoded.checkResults.isEmpty, "a snapshot persisted before this field decodes with no checks")
        // A push: failing again on the new head fires; a new check that already failed fires; no head info stays silent.
        func at(_ oid: String, _ checks: [CheckResult]) -> PRSnapshot { var p = pr(checks: checks); p.headOid = oid; return p }
        assert(events(at("a", [c("X", .failed)]), at("b", [c("X", .failed)])).map(\.trigger) == [.checkFailed], "failed again after a push")
        assert(events(at("a", [c("Y", .passed)]), at("b", [c("X", .failed)])).count == 1, "a check that is new on the new head fires")
        assert(events(at("a", [c("X", .failed)]), at("a", [c("X", .failed)])).isEmpty, "same head, still failing: nothing")
        assert(events(at("", [c("X", .failed)]), at("b", [c("X", .failed)])).isEmpty, "previous had no head: nothing")
        assert(events(at("a", []), at("b", [c("X", .failed)])).isEmpty, "previous had no checks: nothing")
        assert(events(at("b", []), at("b", [c("X", .failed)])).map(\.check) == ["X"], "same head, rollup was empty: a late check fires")
        assert(events(at("b", [c("V", .other)]), at("b", [c("V", .passed), c("X", .failed)])).filter { $0.trigger == .checkFailed }.count == 1,
               "same head, a check that appears later fires")
        assert(CheckContexts.commitSelection(enabled: false).isEmpty, "flag off: no oid in the query")
        print("CHECK HOOK absent-previous OK")

        // AC-5: with the flag off, check triggers are unknown and nothing is fetched.
        assert(PRHookEngine.unknownTriggers(hook(), issues: false, checks: false) == ["check-failed"], "flag off: unknown trigger")
        assert(PRHookEngine.unknownTriggers(hook(), issues: false, checks: true).isEmpty, "flag on: known trigger")
        assert(!PRHookEngine.starterFrontmatter.contains("check-failed"), "flag off: starter does not list check triggers")
        assert(PRHookEngine.starterFrontmatter(issues: false, checks: true).contains("#   check-failed "), "flag on: starter lists them")
        assert(PRHookEngine.starterFrontmatter(issues: false, checks: true).split(separator: "\n").allSatisfy { $0.hasPrefix("#") },
               "check starter is all comments")
        assert(!HookTrigger.allCases.contains { $0.rawValue.hasPrefix("check-") }, "rollup triggers are unchanged")
        assert(!FeatureFlagRegistry.checkHooksEnabled, "check-hooks ships off")
        assert(!CheckContexts.wanted(flagOn: false, templates: [hook()]), "flag off: nothing wanted")
        print("CHECK HOOK flag-off OK")

        // AC-6: the selection is only in the query while wanted, and it is bounded.
        assert(CheckContexts.selection(enabled: false).isEmpty, "flag off: the query text is unchanged")
        let selection = CheckContexts.selection(enabled: true)
        assert(selection.contains("contexts(first: 50)") && selection.contains("CheckRun") && selection.contains("StatusContext"),
               "flag on: bounded contexts with check runs and statuses")
        assert(CheckContexts.wanted(flagOn: true, templates: [hook()]), "flag on + a check hook: wanted")
        assert(!CheckContexts.wanted(flagOn: true, templates: []), "flag on, no hooks: not wanted")
        var plain = hook(); plain.on = "ci-failed"
        assert(!CheckContexts.wanted(flagOn: true, templates: [plain, hook(check: "")]), "no hook names a check: not wanted")
        assert(CheckContexts.state(checkRunConclusion: "TIMED_OUT") == .failed && CheckContexts.state(checkRunConclusion: "CANCELLED") == .other
               && CheckContexts.state(checkRunConclusion: nil) == .other && CheckContexts.state(checkRunConclusion: "SUCCESS") == .passed,
               "check run conclusions")
        assert(CheckContexts.state(statusContext: "ERROR") == .failed && CheckContexts.state(statusContext: "PENDING") == .other,
               "status context states")
        assert(CheckContexts.merged([c("X", .failed), c("X", .passed), c("Y", .passed)]) == [c("X", .failed), c("Y", .passed)],
               "a re-run name collapses to one result, failure winning")
        print("CHECK HOOK query-gated OK")

        // AC-7: the throttle keys two checks apart, and one check once per cooldown.
        let both = events(pr(checks: [c("X", .passed), c("Y", .passed)]), pr(checks: [c("X", .failed), c("Y", .failed)]))
        assert(both.count == 2, "two checks failing yield two events")
        var throttle = PRHookEngine.Throttle()
        let now = Date()
        assert(both.allSatisfy { throttle.admit(key: PRHookEngine.Throttle.key("h", $0), now: now) }, "each check launches once")
        assert(!throttle.admit(key: PRHookEngine.Throttle.key("h", both[0]), now: now.addingTimeInterval(60)), "the same check is throttled")
        assert(PRHookEngine.Throttle.key("h", both[0]) != PRHookEngine.Throttle.key("h", both[1]), "keys differ per check")
        print("CHECK HOOK throttle-per-check OK")
    }
}
#endif
