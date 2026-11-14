import Foundation

// MARK: - Watch level

/// How closely one repo's issues are followed. Default is `.onlyMine`.
enum IssueWatchLevel: String, Codable, CaseIterable {
    case allIssues
    case onlyMine
    case off

    var title: String {
        switch self {
        case .allIssues: return "All issues"
        case .onlyMine: return "Only mine"
        case .off: return "Off"
        }
    }

    static let `default`: IssueWatchLevel = .onlyMine
}

// MARK: - Snapshot

struct IssueReply: Codable, Equatable {
    let author: String
    let createdAt: Date
    /// GitHub `authorAssociation` (OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR, NONE...).
    let association: String

    init(author: String, createdAt: Date, association: String) {
        self.author = author
        self.createdAt = createdAt
        self.association = association
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        association = try c.decodeIfPresent(String.self, forKey: .association) ?? "NONE"
    }

    private enum CodingKeys: String, CodingKey { case author, createdAt, association }
}

/// Canonical diff unit for one issue (the issue-side twin of `PRSnapshot`).
struct IssueSnapshot: Codable, Equatable, Identifiable {
    let nodeId: String
    let number: Int
    let title: String
    let url: String
    let repoFullName: String
    let author: String
    let authorIsBot: Bool
    let assignees: [String]
    let labels: [String]
    let createdAt: Date
    let updatedAt: Date
    let commentCount: Int
    /// The last few comments, oldest first.
    let comments: [IssueReply]
    /// True when the issue (or a recent comment) @-mentions the viewer.
    let mentionsMe: Bool

    var id: String { nodeId }

    init(nodeId: String, number: Int, title: String, url: String, repoFullName: String,
         author: String, authorIsBot: Bool = false, assignees: [String] = [], labels: [String] = [],
         createdAt: Date, updatedAt: Date, commentCount: Int = 0,
         comments: [IssueReply] = [], mentionsMe: Bool = false) {
        self.nodeId = nodeId
        self.number = number
        self.title = title
        self.url = url
        self.repoFullName = repoFullName
        self.author = author
        self.authorIsBot = authorIsBot
        self.assignees = assignees
        self.labels = labels
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.commentCount = commentCount
        self.comments = comments
        self.mentionsMe = mentionsMe
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        repoFullName = try c.decodeIfPresent(String.self, forKey: .repoFullName) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorIsBot = try c.decodeIfPresent(Bool.self, forKey: .authorIsBot) ?? false
        assignees = try c.decodeIfPresent([String].self, forKey: .assignees) ?? []
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        commentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        comments = try c.decodeIfPresent([IssueReply].self, forKey: .comments) ?? []
        mentionsMe = try c.decodeIfPresent(Bool.self, forKey: .mentionsMe) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case nodeId, number, title, url, repoFullName, author, authorIsBot
        case assignees, labels, createdAt, updatedAt, commentCount, comments, mentionsMe
    }

    // MARK: Derived

    var org: String { displayOrg.lowercased() }

    /// The repo owner as GitHub spells it (scope chips show this, like `PRSnapshot.org`).
    var displayOrg: String { repoFullName.split(separator: "/").first.map(String.init) ?? "" }

    func isAuthored(by login: String) -> Bool { PRSnapshot.loginsMatch(author, login) }

    func isAssigned(to login: String) -> Bool {
        assignees.contains { PRSnapshot.loginsMatch($0, login) }
    }

    /// A reply from someone with write-ish standing who did not open the issue.
    var hasMaintainerReply: Bool {
        comments.contains { comment in
            !PRSnapshot.loginsMatch(comment.author, author)
                && ["OWNER", "MEMBER", "COLLABORATOR"].contains(comment.association)
        }
    }

    /// Newest comment by someone other than `login`.
    func latestReplyAt(notBy login: String) -> Date? {
        comments.filter { !PRSnapshot.loginsMatch($0.author, login) }.map(\.createdAt).max()
    }

    /// The conversation's last word is somebody else's, so it is my turn.
    func awaitingMyReply(login: String) -> Bool {
        guard let last = comments.last else { return false }
        return !PRSnapshot.loginsMatch(last.author, login)
    }

    var needsInfo: Bool {
        labels.contains { label in
            let l = label.lowercased()
            return l.contains("needs-info") || l.contains("needs info")
                || l.contains("needs-reproduction") || l.contains("waiting for reporter")
        }
    }

    /// Does `text` @-mention `login` as a whole word (not a prefix of a longer login)?
    static func mentions(_ text: String, login: String) -> Bool {
        guard !login.isEmpty else { return false }
        let haystack = text.lowercased()
        let needle = "@" + login.lowercased()
        var search = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: search) {
            search = r.upperBound..<haystack.endIndex
            // An "@" glued to a word is an email address, not a mention.
            if r.lowerBound > haystack.startIndex {
                let prev = haystack[haystack.index(before: r.lowerBound)]
                if prev.isLetter || prev.isNumber || prev == "_" || prev == "-" { continue }
            }
            if r.upperBound == haystack.endIndex { return true }
            let next = haystack[r.upperBound]
            if !(next.isLetter || next.isNumber || next == "-" || next == "_") { return true }
        }
        return false
    }
}

// MARK: - Sections

enum IssueSection: Int, CaseIterable {
    case needsYou, assigned, waitingOnReporter, muted

    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .assigned: return "Assigned"
        case .waitingOnReporter: return "Waiting on reporter"
        case .muted: return "Muted"
        }
    }
}

/// Why an issue is worth showing in the Inbox. Lower raw value ranks higher.
enum IssueInboxReason: Int {
    case assigned = 0, reply, mentioned, newIssue
}

enum IssueClassifier {
    static func section(for issue: IssueSnapshot, myLogin: String, muted: Bool) -> IssueSection {
        if muted { return .muted }
        if issue.isAuthored(by: myLogin) {
            return issue.awaitingMyReply(login: myLogin) ? .needsYou : .assigned
        }
        if issue.isAssigned(to: myLogin) { return .assigned }
        if issue.needsInfo { return .waitingOnReporter }
        if !issue.assignees.isEmpty { return .assigned }
        if !issue.hasMaintainerReply { return .needsYou }
        return .waitingOnReporter
    }

    /// Why this issue belongs in the Inbox, or nil when it is background noise.
    static func inboxReason(for issue: IssueSnapshot, myLogin: String) -> IssueInboxReason {
        if issue.isAssigned(to: myLogin) { return .assigned }
        // An issue I opened counts only once somebody else has the last word.
        if issue.isAuthored(by: myLogin), issue.awaitingMyReply(login: myLogin) { return .reply }
        if issue.mentionsMe { return .mentioned }
        return .newIssue
    }

    struct InboxSelection {
        let items: [IssueSnapshot]
        /// New issues from All-issues repos withheld because the setting is off.
        let hiddenNew: Int
    }

    /// Issues that surface in the Inbox, ranked (reason, then most recently updated).
    /// Assigned, mention and reply issues are always shown; `.newIssue` ones only when `showNew`.
    /// Muted issues never show. Each issue appears once.
    /// `newIssueAllowed` says whether a repo follows new issues at all (All issues). The
    /// `involves:@me` search also returns issues the user only commented on, so without
    /// this an Only-mine repo would surface them as "new".
    static func inboxItems(_ issues: [IssueSnapshot], myLogin: String, muted: Set<String>,
                           showNew: Bool,
                           newIssueAllowed: (String) -> Bool = { _ in true }) -> InboxSelection {
        var seen = Set<String>()
        var kept: [(IssueInboxReason, IssueSnapshot)] = []
        var hidden = 0
        for issue in issues where !muted.contains(issue.nodeId) && seen.insert(issue.nodeId).inserted {
            let reason = inboxReason(for: issue, myLogin: myLogin)
            if reason == .newIssue {
                guard newIssueAllowed(issue.repoFullName) else { continue }
                // Only unanswered, unassigned issues count as "new" for the Inbox.
                guard section(for: issue, myLogin: myLogin, muted: false) == .needsYou else { continue }
                if !showNew { hidden += 1; continue }
            }
            kept.append((reason, issue))
        }
        kept.sort { a, b in
            a.0 != b.0 ? a.0.rawValue < b.0.rawValue : a.1.updatedAt > b.1.updatedAt
        }
        return InboxSelection(items: kept.map { $0.1 }, hiddenNew: hidden)
    }

    /// Issues that need the viewer's time (feeds the menu-bar badge). Each issue counted once.
    static func needsMyTimeCount(_ issues: [IssueSnapshot], myLogin: String, muted: Set<String>,
                                 showNew: Bool,
                                 newIssueAllowed: (String) -> Bool = { _ in true }) -> Int {
        inboxItems(issues, myLogin: myLogin, muted: muted, showNew: showNew,
                   newIssueAllowed: newIssueAllowed).items.count
    }
}

#if DEBUG
enum IssueChecks {
    private static func issue(_ id: String, author: String = "alice", assignees: [String] = [],
                              labels: [String] = [], comments: [IssueReply] = [],
                              mentions: Bool = false) -> IssueSnapshot {
        IssueSnapshot(nodeId: id, number: 1, title: "t", url: "u", repoFullName: "Acme/app",
                      author: author, assignees: assignees, labels: labels,
                      createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200),
                      commentCount: comments.count, comments: comments, mentionsMe: mentions)
    }

    static func run() {
        let me = "Mads"
        let maint = IssueReply(author: "bob", createdAt: Date(timeIntervalSince1970: 150), association: "MEMBER")
        let drive = IssueReply(author: "carol", createdAt: Date(timeIntervalSince1970: 160), association: "NONE")

        assert(IssueWatchLevel.default == .onlyMine, "default watch level is Only mine")
        assert(IssueWatchLevel.allCases.map(\.title) == ["All issues", "Only mine", "Off"], "watch level labels")

        assert(IssueSnapshot.mentions("ping @mads please", login: me), "mention matches case-insensitively")
        assert(!IssueSnapshot.mentions("ping @madsen please", login: me), "mention is a whole word")
        assert(IssueSnapshot.mentions("cc @mads", login: me), "mention at end of text")
        assert(!IssueSnapshot.mentions("write to ops@mads.example.com", login: me), "an email address is not a mention")
        assert(IssueSnapshot.mentions("(@mads) thoughts?", login: me), "mention after punctuation")

        let fresh = issue("a")
        assert(fresh.displayOrg == "Acme" && fresh.org == "acme", "chips show the org as spelled; matching is lowercase")
        assert(IssueClassifier.section(for: fresh, myLogin: me, muted: false) == .needsYou, "unanswered unassigned → Needs you")
        assert(IssueClassifier.section(for: issue("b", comments: [maint]), myLogin: me, muted: false) == .waitingOnReporter,
               "maintainer replied → Waiting on reporter")
        assert(IssueClassifier.section(for: issue("c", assignees: ["mads"]), myLogin: me, muted: false) == .assigned, "assigned to me → Assigned")
        assert(IssueClassifier.section(for: issue("d", labels: ["Needs-Info"]), myLogin: me, muted: false) == .waitingOnReporter,
               "needs-info label → Waiting on reporter")
        assert(IssueClassifier.section(for: fresh, myLogin: me, muted: true) == .muted, "muted wins")
        assert(IssueClassifier.section(for: issue("e", author: "mads", comments: [drive]), myLogin: me, muted: false) == .needsYou,
               "reply on my issue → Needs you")

        let items = [fresh, issue("c", assignees: ["mads"]), issue("m", mentions: true), issue("c", assignees: ["mads"])]
        let on = IssueClassifier.inboxItems(items, myLogin: me, muted: [], showNew: true)
        assert(on.items.map(\.nodeId) == ["c", "m", "a"], "inbox dedups and ranks assigned > mention > new")
        assert(on.items.filter { $0.nodeId == "c" }.count == 1, "each issue appears once")
        let off = IssueClassifier.inboxItems(items, myLogin: me, muted: [], showNew: false)
        assert(off.hiddenNew == 1 && !off.items.contains { $0.nodeId == "a" }, "new issues hidden when setting off")
        assert(IssueClassifier.needsMyTimeCount(items, myLogin: me, muted: ["c"], showNew: false) == 1, "muted excluded from badge count")
        let gated = IssueClassifier.inboxItems(items, myLogin: me, muted: [], showNew: true, newIssueAllowed: { _ in false })
        assert(!gated.items.contains { $0.nodeId == "a" } && gated.hiddenNew == 0, "an Only-mine repo's unanswered issue is not 'new'")

        let mineQuiet = issue("q", author: "mads")
        let mineAnswered = issue("r", author: "mads", comments: [drive])
        let mine = IssueClassifier.inboxItems([mineQuiet, mineAnswered], myLogin: me, muted: [], showNew: true)
        assert(!mine.items.contains { $0.nodeId == "q" }, "my issue with no reply to answer stays out of the Inbox")
        assert(mine.items.map(\.nodeId) == ["r"], "my issue awaiting my reply is in the Inbox")

        IssueDiffChecks.run()
    }
}
#endif
