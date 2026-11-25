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

    var meaning: String {
        switch self {
        case .approved: return "the PR became approved"
        case .changesRequested: return "a reviewer requested changes"
        case .ciFailed: return "CI turned red"
        case .ciPassed: return "CI turned green"
        case .conflict: return "the PR got a merge conflict"
        case .readyToMerge: return "approved, green, mergeable and not queued"
        case .newComment: return "a new human comment or review"
        case .reviewRequested: return "a review was requested from you"
        case .readyForReview: return "a draft became ready"
        case .merged: return "the PR was merged"
        case .closed: return "the PR was closed without merging"
        }
    }
}

struct HookEvent: Equatable {
    let trigger: HookTrigger
    let pr: PRSnapshot
}

/// Whose PRs a hook may fire on. Default `.authored`: an agent must not start by itself on
/// content a stranger wrote unless the hook says so.
enum HookRole: String {
    case authored, reviewing, any

    static func parse(_ text: String) -> HookRole { HookRole(rawValue: text.lowercased()) ?? .authored }
}

/// Pure hook logic: which events a poll produced, which templates they fire, and how often.
enum PRHookEngine {
    /// Events between two snapshot sets. A PR with no previous snapshot is a baseline, never
    /// an event — so the first poll, and a PR first seen after an incomplete fetch, fire nothing.
    static func events(previous: [String: PRSnapshot], next: [PRSnapshot], myLogin: String) -> [HookEvent] {
        var out: [HookEvent] = []
        for pr in next {
            guard let old = previous[pr.nodeId] else { continue }
            func add(_ t: HookTrigger) { out.append(HookEvent(trigger: t, pr: pr)) }

            if old.reviewDecision != .approved, pr.reviewDecision == .approved { add(.approved) }
            if old.reviewDecision != .changesRequested, pr.reviewDecision == .changesRequested { add(.changesRequested) }
            let failed: (CIStatus) -> Bool = { $0 == .failure || $0 == .error }
            if !failed(old.ciStatus), failed(pr.ciStatus) { add(.ciFailed) }
            if old.ciStatus != .success, pr.ciStatus == .success { add(.ciPassed) }
            if old.mergeable != false, pr.mergeable == false { add(.conflict) }
            let oldTokens = PromptState.active(pr: old, myLogin: myLogin)
            if !oldTokens.contains("ready-to-merge"),
               PromptState.active(pr: pr, myLogin: myLogin).contains("ready-to-merge") { add(.readyToMerge) }
            let newComment = pr.commentCount > old.commentCount && !pr.lastCommentIsBot
            let newReview = pr.reviewCount > old.reviewCount && !pr.lastReviewIsBot
            if newComment || newReview { add(.newComment) }
            if !old.tabs.contains(.forMe), pr.tabs.contains(.forMe) { add(.reviewRequested) }
            if old.isDraft, !pr.isDraft { add(.readyForReview) }
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
    static func parseTriggers(_ text: String) -> (triggers: [HookTrigger], unknown: [String]) {
        var triggers: [HookTrigger] = [], unknown: [String] = []
        for word in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !word.isEmpty {
            if let t = HookTrigger(rawValue: word) { if !triggers.contains(t) { triggers.append(t) } } else { unknown.append(word) }
        }
        return (triggers, unknown)
    }

    static func isHook(_ t: PromptTemplate) -> Bool { !parseTriggers(t.on).triggers.isEmpty }

    /// Whether `template` fires for `event`: trigger, repo scope, role, then the `when:` guard.
    static func matches(_ t: PromptTemplate, event: HookEvent, myLogin: String) -> Bool {
        guard parseTriggers(t.on).triggers.contains(event.trigger) else { return false }
        let repo = event.pr.repoFullName
        let scopes = CommentEngine.parseScope(t.hookScope)
        guard scopes.isEmpty || scopes.contains(where: { CommentEngine.patternMatches($0, repo: repo) }) else { return false }
        let state = PromptState.active(pr: event.pr, myLogin: myLogin)
        switch HookRole.parse(t.hookRole) {
        // `authored` means YOU opened it. `PromptState`'s `authored` token also covers a PR you merely
        // committed to, and commit authorship (a `Co-authored-by:` trailer, an email) is forgeable by a
        // stranger — so a hook never trusts it. `role: any` is the explicit opt-in.
        case .authored: guard PRSnapshot.loginsMatch(event.pr.author, myLogin) else { return false }
        case .reviewing: guard state.contains("reviewing") else { return false }
        case .any: break
        }
        if !t.when.trimmingCharacters(in: .whitespaces).isEmpty,
           PromptState.matchedAlternative(t.when, active: state) == nil { return false }
        return true
    }

    /// Per-PR-per-hook-per-trigger cooldown plus a global hourly cap, so a flapping check or a
    /// bad hook can't start agent after agent. Value type; `now` is passed in.
    struct Throttle {
        var cooldown: TimeInterval = 30 * 60
        var hourlyCap = 10
        private(set) var lastFired: [String: Date] = [:]
        private(set) var launches: [Date] = []

        static func key(_ hook: String, _ event: HookEvent) -> String { "\(hook)|\(event.trigger.rawValue)|\(event.pr.nodeId)" }

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

#if DEBUG
enum PRHookChecks {
    static func run() {
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
        assert(PRHookEngine.events(previous: [:], next: [pr()], myLogin: "me").isEmpty, "new PR is a baseline, not an event")
        assert(triggers(pr(), pr(decision: .approved)) == [.approved], "approved")
        assert(triggers(pr(decision: .approved), pr(decision: .approved)).isEmpty, "steady state fires nothing")
        assert(triggers(pr(), pr(ci: .failure)).contains(.ciFailed), "ci-failed")
        assert(triggers(pr(ci: .failure), pr(ci: .error)).isEmpty, "failure → error is not a new failure")
        assert(triggers(pr(), pr(ci: .success)).contains(.ciPassed), "ci-passed")
        assert(triggers(pr(), pr(mergeable: false)).contains(.conflict), "conflict")
        assert(triggers(pr(draft: true), pr()).contains(.readyForReview), "draft → ready")

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
#endif
