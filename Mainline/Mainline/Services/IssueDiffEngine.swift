import Foundation

/// What changed about an issue between two polls. One transition per issue per poll.
enum IssueTransition: Equatable {
    case newIssue(IssueSnapshot)
    case assigned(IssueSnapshot)
    case mentioned(IssueSnapshot)
    case reply(IssueSnapshot)

    var issue: IssueSnapshot {
        switch self {
        case .newIssue(let i), .assigned(let i), .mentioned(let i), .reply(let i): return i
        }
    }

    var event: PREvent {
        switch self {
        case .newIssue: return .newIssue
        case .assigned: return .issueAssigned
        case .mentioned: return .issueMentioned
        case .reply: return .issueReply
        }
    }

    /// Bounded kind label for notification IDs and telemetry.
    var kind: String {
        switch self {
        case .newIssue: return "new"
        case .assigned: return "assigned"
        case .mentioned: return "mentioned"
        case .reply: return "reply"
        }
    }
}

enum IssueDiffEngine {
    /// A "new" issue older than this when first seen is history, not news (keeps a repo
    /// switched from Off to All issues from announcing its whole backlog).
    static let newIssueMaxAge: TimeInterval = 3 * 24 * 3600

    /// Pure diff. `watchLevel` resolves a repo's level. Never yields anything for an Off repo,
    /// nor for a repo in `seedRepos` (lowercased names): one switched on from Off has no baseline,
    /// so its existing assignments and mentions are seeded silently rather than announced.
    static func diff(previous: [String: IssueSnapshot], next: [IssueSnapshot], myLogin: String,
                     watchLevel: (String) -> IssueWatchLevel, seedRepos: Set<String> = [],
                     now: Date) -> [IssueTransition] {
        guard !myLogin.isEmpty else { return [] }
        var out: [IssueTransition] = []
        for issue in next {
            let level = watchLevel(issue.repoFullName)
            if level == .off || seedRepos.contains(issue.repoFullName.lowercased()) { continue }
            let old = previous[issue.nodeId]

            if issue.isAuthored(by: myLogin) {
                // My own issue: only a fresh reply from someone else is news.
                guard let latest = issue.latestReplyAt(notBy: myLogin) else { continue }
                let before = old?.latestReplyAt(notBy: myLogin)
                if old != nil, before == nil || latest > before! { out.append(.reply(issue)) }
                continue
            }

            let assignedNow = issue.isAssigned(to: myLogin)
            let assignedBefore = old?.isAssigned(to: myLogin) ?? false
            if assignedNow && !assignedBefore {
                out.append(.assigned(issue))
            } else if issue.mentionsMe && !(old?.mentionsMe ?? false) {
                out.append(.mentioned(issue))
            } else if level == .allIssues, old == nil,
                      now.timeIntervalSince(issue.createdAt) <= newIssueMaxAge {
                out.append(.newIssue(issue))
            }
        }
        return out
    }

    struct CarryResult {
        let issues: [IssueSnapshot]
        let carried: Int
    }

    /// An incomplete fetch must not shrink the diff baseline (it would re-notify later):
    /// re-add, verbatim, each previous issue the fetch lacks that an incomplete query could
    /// have returned (`mayCarry`). An issue only a complete query covers left the set: drop it.
    static func carryingForward(fetched: [IssueSnapshot], previous: [String: IssueSnapshot],
                                mayCarry: (IssueSnapshot) -> Bool) -> CarryResult {
        let have = Set(fetched.map(\.nodeId))
        let missing = previous.values.filter { !have.contains($0.nodeId) && mayCarry($0) }
        return CarryResult(issues: fetched + missing, carried: missing.count)
    }
}

#if DEBUG
enum IssueDiffChecks {
    private static func mk(_ id: String, repo: String = "acme/app", author: String = "alice",
                           assignees: [String] = [], mentions: Bool = false,
                           comments: [IssueReply] = [], created: TimeInterval = 1_000_000) -> IssueSnapshot {
        IssueSnapshot(nodeId: id, number: 1, title: "t", url: "u", repoFullName: repo, author: author,
                      assignees: assignees, createdAt: Date(timeIntervalSince1970: created),
                      updatedAt: Date(timeIntervalSince1970: created), comments: comments, mentionsMe: mentions)
    }

    static func run() {
        let me = "mads"
        let now = Date(timeIntervalSince1970: 1_000_100)
        let all: (String) -> IssueWatchLevel = { _ in .allIssues }
        let mine: (String) -> IssueWatchLevel = { _ in .onlyMine }
        let off: (String) -> IssueWatchLevel = { _ in .off }

        let a = mk("a")
        assert(IssueDiffEngine.diff(previous: [:], next: [a], myLogin: me, watchLevel: all, now: now).map(\.kind) == ["new"],
               "new issue in an All-issues repo")
        assert(IssueDiffEngine.diff(previous: [:], next: [a], myLogin: me, watchLevel: mine, now: now).isEmpty,
               "no new-issue transition for Only mine")
        assert(IssueDiffEngine.diff(previous: [:], next: [a], myLogin: me, watchLevel: off, now: now).isEmpty,
               "nothing for an Off repo")
        assert(IssueDiffEngine.diff(previous: ["a": a], next: [a], myLogin: me, watchLevel: all, now: now).isEmpty,
               "an unchanged issue is silent")
        let stale = mk("s", created: 0)
        assert(IssueDiffEngine.diff(previous: [:], next: [stale], myLogin: me, watchLevel: all, now: now).isEmpty,
               "an old backlog issue is not announced")
        assert(IssueDiffEngine.diff(previous: [:], next: [mk("m", author: "mads")], myLogin: me, watchLevel: all, now: now).isEmpty,
               "my own new issue is silent")

        let assigned = mk("a", assignees: ["Mads"])
        assert(IssueDiffEngine.diff(previous: ["a": a], next: [assigned], myLogin: me, watchLevel: mine, now: now).map(\.kind) == ["assigned"],
               "assignment yields assigned")
        assert(IssueDiffEngine.diff(previous: ["a": assigned], next: [assigned], myLogin: me, watchLevel: mine, now: now).isEmpty,
               "an existing assignment is silent")
        let mentioned = mk("a", mentions: true)
        assert(IssueDiffEngine.diff(previous: ["a": a], next: [mentioned], myLogin: me, watchLevel: mine, now: now).map(\.kind) == ["mentioned"],
               "new mention yields mentioned")
        assert(IssueDiffEngine.diff(previous: ["a": a], next: [mk("a", assignees: ["mads"], mentions: true)],
                                    myLogin: me, watchLevel: mine, now: now).count == 1,
               "one transition per issue per poll")

        let mineIssue = mk("o", author: "mads")
        let reply = IssueReply(author: "bob", createdAt: Date(timeIntervalSince1970: 1_000_050), association: "NONE")
        let replied = mk("o", author: "mads", comments: [reply])
        assert(IssueDiffEngine.diff(previous: ["o": mineIssue], next: [replied], myLogin: me, watchLevel: mine, now: now).map(\.kind) == ["reply"],
               "reply on my issue")
        let own = IssueReply(author: "mads", createdAt: Date(timeIntervalSince1970: 1_000_060), association: "OWNER")
        assert(IssueDiffEngine.diff(previous: ["o": mineIssue], next: [mk("o", author: "mads", comments: [own])],
                                    myLogin: me, watchLevel: mine, now: now).isEmpty,
               "my own comment is not a reply")
        assert(IssueDiffEngine.diff(previous: ["o": replied], next: [replied], myLogin: me, watchLevel: mine, now: now).isEmpty,
               "an already-seen reply is silent")

        // A repo switched on from Off has no baseline: its existing assignments seed silently.
        assert(IssueDiffEngine.diff(previous: [:], next: [assigned, mentioned], myLogin: me, watchLevel: mine,
                                    seedRepos: ["acme/app"], now: now).isEmpty,
               "a repo re-enabled from Off seeds silently")
        assert(IssueDiffEngine.diff(previous: [:], next: [mk("x", repo: "acme/other", assignees: ["mads"])], myLogin: me,
                                    watchLevel: mine, seedRepos: ["acme/app"], now: now).map(\.kind) == ["assigned"],
               "seeding one repo leaves the others notifying")

        let kept = IssueDiffEngine.carryingForward(fetched: [], previous: ["a": a], mayCarry: { _ in true })
        assert(kept.issues.count == 1 && kept.carried == 1, "incomplete fetch carries previous issues forward")
        let dropped = IssueDiffEngine.carryingForward(fetched: [], previous: ["a": a], mayCarry: { _ in false })
        assert(dropped.issues.isEmpty && dropped.carried == 0, "complete fetch drops issues that left the set")
        // Only the issues an incomplete query covers are carried: with the involves search
        // complete, an unassigned issue in an "Only mine" repo leaves even if a broad search was cut.
        let mineRepo = mk("m", repo: "acme/mine"), allRepo = mk("b", repo: "acme/all")
        let scoped = IssueDiffEngine.carryingForward(
            fetched: [], previous: ["m": mineRepo, "b": allRepo],
            mayCarry: { $0.repoFullName == "acme/all" })
        assert(scoped.issues.map(\.nodeId) == ["b"] && scoped.carried == 1,
               "carry-forward is limited to issues an incomplete query could return")
        // Carried issues diff to nothing, so an incomplete poll can never re-notify.
        assert(IssueDiffEngine.diff(previous: ["a": a], next: kept.issues, myLogin: me, watchLevel: all, now: now).isEmpty,
               "carry-forward yields no transitions")
    }
}
#endif
