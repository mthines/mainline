import Foundation

/// Pure formatter that turns a section's PRs into a Markdown list for the clipboard.
///
/// The output is shaped to be pasted into an agent ("which of these are ready to
/// merge?"), so every PR carries its URL plus the state the deck already shows —
/// CI, review decision, draft, conflicts, unresolved threads, size, branch — as
/// plain words rather than icons. No I/O; `PRListExportChecks` asserts it.
enum PRListExport {

    /// Just the list, no heading — the user pastes it under their own prompt.
    /// - Parameter prs: the section's PRs, in display order.
    static func markdown(prs: [PRSnapshot]) -> String {
        var lines: [String] = []
        for pr in prs {
            lines.append("- [\(pr.repoFullName)#\(pr.number)](\(pr.htmlUrl)) \(pr.title)")
            lines.append("  - \(details(pr).joined(separator: " · "))")
        }
        return lines.joined(separator: "\n")
    }

    /// The per-PR status line, most decision-relevant facts first.
    static func details(_ pr: PRSnapshot) -> [String] {
        var parts: [String] = []
        if !pr.author.isEmpty { parts.append("author: @\(pr.author)") }
        if pr.merged {
            parts.append("merged")
        } else if pr.closed {
            parts.append("closed")
        } else if pr.isDraft {
            parts.append("draft")
        }
        parts.append("CI: \(ciLabel(pr.ciStatus))")
        parts.append("review: \(reviewLabel(pr.reviewDecision))")
        if pr.mergeable == false { parts.append("merge conflict") }
        if pr.unresolvedThreadCount > 0 {
            let noun = pr.unresolvedThreadCount == 1 ? "thread" : "threads"
            parts.append("\(pr.unresolvedThreadCount) unresolved \(noun)")
        }
        parts.append("+\(pr.linesAdded) −\(pr.linesDeleted)")
        if !pr.headRefName.isEmpty {
            let base = pr.baseRefName.isEmpty ? "" : " → \(pr.baseRefName)"
            parts.append("branch: `\(pr.headRefName)`\(base)")
        }
        return parts
    }

    private static func ciLabel(_ status: CIStatus) -> String {
        switch status {
        case .success: return "passing"
        case .failure: return "failing"
        case .error:   return "error"
        case .pending: return "pending"
        case .unknown: return "none"
        }
    }

    private static func reviewLabel(_ decision: ReviewDecision?) -> String {
        switch decision {
        case .approved:         return "approved"
        case .changesRequested: return "changes requested"
        case .reviewRequired:   return "review required"
        case nil:               return "none"
        }
    }
}

#if DEBUG
enum PRListExportChecks {
    static func run() {
        let green = PRSnapshot(
            nodeId: "a", number: 12, title: "feat: thing", htmlUrl: "https://github.com/o/r/pull/12",
            repoFullName: "o/r", isDraft: false, state: "open", reviewDecision: .approved,
            ciStatus: .success, reviewState: .approved, commentCount: 0, updatedAt: "",
            author: "me", requestedReviewers: [], mergeable: true,
            headRefName: "feat/thing", baseRefName: "main", linesAdded: 10, linesDeleted: 2
        )
        let blocked = PRSnapshot(
            nodeId: "b", number: 7, title: "fix: other", htmlUrl: "https://github.com/o/r/pull/7",
            repoFullName: "o/r", isDraft: true, state: "open", reviewDecision: .changesRequested,
            ciStatus: .failure, reviewState: .changesRequested, commentCount: 0, updatedAt: "",
            author: "", requestedReviewers: [], mergeable: false,
            unresolvedThreadCount: 1
        )

        let out = PRListExport.markdown(prs: [green, blocked])
        let lines = out.components(separatedBy: "\n")
        assert(lines.count == 4, "two lines per PR, no heading")
        assert(lines[0] == "- [o/r#12](https://github.com/o/r/pull/12) feat: thing", "row links repo#number to the URL")
        assert(lines[1] == "  - author: @me · CI: passing · review: approved · +10 −2 · branch: `feat/thing` → main",
               "green PR details")
        assert(lines[3] == "  - draft · CI: failing · review: changes requested · merge conflict · 1 unresolved thread · +0 −0",
               "blocked PR: draft/conflict/thread flags; empty author and branch omitted")
    }
}
#endif
