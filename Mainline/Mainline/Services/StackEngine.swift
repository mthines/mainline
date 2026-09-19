import Foundation

/// Pure stacked-PR detection.
///
/// A **stack** is a chain of open PRs where each PR's base branch is another open
/// PR's head branch, within the SAME repo — i.e. PR B is "stacked on" PR A when
/// `B.baseRefName == A.headRefName`. Stacks merge bottom-up, so members are always
/// ordered **bottom → top** (the base-most PR first).
///
/// Detection rules:
/// - Only OPEN PRs link. A merged/closed PR is never a stack member: once the base
///   PR merges, GitHub retargets the child at the default branch anyway, so a
///   merged base is no longer a live link — the child becomes its own root.
/// - Branch names are keyed per repo (`repoFullName` + ref). Branch names are not
///   unique across forks, so a bare ref match would wrongly link two repos' PRs.
/// - A stack needs **≥ 2** members. A lone PR is standalone, not a one-item stack.
/// - Detection only sees the PRs it is handed. If a middle PR lives in a repo/tab
///   you don't watch, the chain breaks at the gap and each side is its own stack (or
///   standalone). Callers can backfill via on-demand fetch later.
///
/// Pure — no I/O, no `@MainActor`, safe to call from any thread. Mirrors the
/// `PRDiffEngine` / `InboxMuteEngine` pure-shell pattern, with `StackEngineChecks`
/// self-checks below.
enum StackEngine {

    /// A detected stack: an ordered chain of PRs, bottom (base-most) first.
    /// Always has ≥ 2 members.
    struct Stack: Equatable, Identifiable {
        /// Members ordered bottom → top. `members[0]` is the base-most PR.
        let members: [PRSnapshot]

        /// Stable identity across polls: the bottom PR's nodeId. The bottom is the
        /// anchor a stack is placed and pinned by, and it changes only when the base
        /// itself merges out — exactly when the stack's identity should change.
        var id: String { members.first?.nodeId ?? "" }

        /// The base-most PR — the one that merges first.
        var bottom: PRSnapshot { members[0] }

        /// The tip PR — the one that merges last.
        var top: PRSnapshot { members[members.count - 1] }

        var nodeIds: [String] { members.map(\.nodeId) }
        var count: Int { members.count }
    }

    /// An O(1)-lookup view over the stacks detected in a PR list. Built once per
    /// render/population pass and queried per row.
    struct Index: Equatable {
        /// All detected stacks (each ≥ 2 members), bottom → top.
        let stacks: [Stack]

        /// nodeId → the id of the stack that contains it.
        private let stackIdByNode: [String: String]
        /// stack.id → Stack, for lookup by id.
        private let stackById: [String: Stack]
        /// nodeId → 0-based position within its stack (0 = bottom).
        private let positionByNode: [String: Int]

        init(stacks: [Stack]) {
            self.stacks = stacks
            var idByNode: [String: String] = [:]
            var byId: [String: Stack] = [:]
            var posByNode: [String: Int] = [:]
            for stack in stacks {
                byId[stack.id] = stack
                for (i, member) in stack.members.enumerated() {
                    idByNode[member.nodeId] = stack.id
                    posByNode[member.nodeId] = i
                }
            }
            self.stackIdByNode = idByNode
            self.stackById = byId
            self.positionByNode = posByNode
        }

        static let empty = Index(stacks: [])

        /// Whether this PR is part of a detected stack.
        func isStacked(_ nodeId: String) -> Bool { stackIdByNode[nodeId] != nil }

        /// The stack containing this PR, or nil if it is standalone.
        func stack(containing nodeId: String) -> Stack? {
            guard let sid = stackIdByNode[nodeId] else { return nil }
            return stackById[sid]
        }

        /// 1-based position `(index, count)` of this PR within its stack, bottom → top
        /// (bottom is 1). nil when standalone. Drives the "2/3" badge.
        func position(of nodeId: String) -> (index: Int, count: Int)? {
            guard let sid = stackIdByNode[nodeId],
                  let stack = stackById[sid],
                  let zero = positionByNode[nodeId] else { return nil }
            return (zero + 1, stack.count)
        }

        /// The nodeId directly below this one in its stack (its base PR), or nil if it
        /// is the bottom / standalone.
        func baseNode(of nodeId: String) -> String? {
            guard let sid = stackIdByNode[nodeId],
                  let stack = stackById[sid],
                  let zero = positionByNode[nodeId], zero > 0 else { return nil }
            return stack.members[zero - 1].nodeId
        }

        /// Whether this PR is blocked purely because the PR directly below it in the
        /// stack is still open (can't merge until the base merges). True for every
        /// non-bottom stack member (all stack members are open by construction).
        /// The bottom member — and any standalone PR — is never blocked by an open base.
        func blockedByOpenBase(_ nodeId: String) -> Bool {
            guard let zero = positionByNode[nodeId] else { return false }
            return zero > 0
        }
    }

    /// Detect the stacks in a flat PR list. Order of the returned stacks follows the
    /// input order of each stack's bottom PR, so callers keep a stable placement.
    static func detect(_ prs: [PRSnapshot]) -> [Stack] {
        let open = prs.filter { !$0.merged && !$0.closed }
        guard open.count >= 2 else { return [] }

        func headKey(_ repo: String, _ ref: String) -> String { repo + "\n" + ref }

        // head branch → PR (per repo). One open PR per head branch, so this is 1:1.
        var byHead: [String: PRSnapshot] = [:]
        for pr in open where !pr.headRefName.isEmpty {
            byHead[headKey(pr.repoFullName, pr.headRefName)] = pr
        }

        // Directed base/head links: parentOf[child] = the PR it is stacked on.
        var parentOf: [String: PRSnapshot] = [:]
        var childrenOf: [String: [PRSnapshot]] = [:]
        for pr in open where !pr.baseRefName.isEmpty {
            guard let parent = byHead[headKey(pr.repoFullName, pr.baseRefName)],
                  parent.nodeId != pr.nodeId else { continue }
            parentOf[pr.nodeId] = parent
            childrenOf[parent.nodeId, default: []].append(pr)
        }
        guard !parentOf.isEmpty else { return [] }

        let byId = Dictionary(open.map { ($0.nodeId, $0) }, uniquingKeysWith: { a, _ in a })

        // Undirected adjacency over the linked nodes → connected components (stacks).
        var adj: [String: Set<String>] = [:]
        for (childId, parent) in parentOf {
            adj[childId, default: []].insert(parent.nodeId)
            adj[parent.nodeId, default: []].insert(childId)
        }

        // Preserve the input ordering of bottoms: walk open PRs in input order and
        // emit each unseen component once.
        var visitedComponent: Set<String> = []
        var stacks: [Stack] = []

        for seed in open where adj[seed.nodeId] != nil && !visitedComponent.contains(seed.nodeId) {
            // Collect the whole connected component (BFS over undirected edges).
            var component: Set<String> = []
            var frontier = [seed.nodeId]
            while let nodeId = frontier.popLast() {
                guard !component.contains(nodeId) else { continue }
                component.insert(nodeId)
                for neighbour in adj[nodeId] ?? [] where !component.contains(neighbour) {
                    frontier.append(neighbour)
                }
            }
            visitedComponent.formUnion(component)
            guard component.count >= 2 else { continue }

            // Order bottom → top: start from roots (no parent within the component),
            // DFS down children so a chain stays contiguous. Ties broken by PR number
            // ascending (lower numbers are usually created — and thus stacked — first).
            let roots = component
                .filter { parentOf[$0] == nil }
                .compactMap { byId[$0] }
                .sorted { $0.number < $1.number }

            var ordered: [PRSnapshot] = []
            var seen: Set<String> = []
            func visit(_ id: String) {
                guard !seen.contains(id), let pr = byId[id] else { return }
                seen.insert(id)
                ordered.append(pr)
                let kids = (childrenOf[id] ?? []).sorted { $0.number < $1.number }
                for kid in kids { visit(kid.nodeId) }
            }
            for root in roots { visit(root.nodeId) }
            // Cycle safety: emit any component node the DFS didn't reach.
            for id in component where !seen.contains(id) { visit(id) }

            if ordered.count >= 2 { stacks.append(Stack(members: ordered)) }
        }

        return stacks
    }

    /// Convenience: detect and wrap in an `Index` for lookups.
    static func index(_ prs: [PRSnapshot]) -> Index { Index(stacks: detect(prs)) }
}

// MARK: - Self-checks (DEBUG)

#if DEBUG
/// Dependency-free assertions for `StackEngine`. Invoked once at launch alongside
/// the other pure-type self-checks, so a detection regression trips an assertion in
/// a debug build without a full XCTest target.
enum StackEngineChecks {
    private static func make(
        _ nodeId: String,
        number: Int,
        repo: String = "o/r",
        head: String,
        base: String,
        merged: Bool = false,
        closed: Bool = false
    ) -> PRSnapshot {
        PRSnapshot(
            nodeId: nodeId, number: number, title: "#\(number)", htmlUrl: "u",
            repoFullName: repo, isDraft: false, state: merged || closed ? "closed" : "open",
            merged: merged, closed: closed, ciStatus: .success, reviewState: .none,
            commentCount: 0, updatedAt: "", author: "me", requestedReviewers: [],
            headRefName: head, baseRefName: base
        )
    }

    static func run() {
        // A linear stack of three: main ← a ← b ← c.
        let a = make("a", number: 1, head: "feat/a", base: "main")
        let b = make("b", number: 2, head: "feat/b", base: "feat/a")
        let c = make("c", number: 3, head: "feat/c", base: "feat/b")
        // A standalone PR straight off main.
        let solo = make("solo", number: 9, head: "feat/solo", base: "main")

        let stacks = StackEngine.detect([c, solo, a, b]) // deliberately shuffled
        assert(stacks.count == 1, "one stack detected among shuffled input")
        assert(stacks[0].nodeIds == ["a", "b", "c"], "ordered bottom → top regardless of input order")
        assert(stacks[0].bottom.nodeId == "a" && stacks[0].top.nodeId == "c", "bottom/top resolved")
        assert(stacks[0].id == "a", "stack id is the bottom's nodeId")

        let idx = StackEngine.index([c, solo, a, b])
        assert(idx.isStacked("b") && !idx.isStacked("solo"), "membership")
        assert(idx.position(of: "a")?.index == 1 && idx.position(of: "c")?.index == 3, "1-based position")
        assert(idx.position(of: "b")?.count == 3, "count is stack size")
        assert(idx.position(of: "solo") == nil, "standalone has no position")
        assert(idx.baseNode(of: "c") == "b" && idx.baseNode(of: "a") == nil, "base node lookup")
        assert(!idx.blockedByOpenBase("a"), "bottom is never blocked by an open base")
        assert(idx.blockedByOpenBase("b") && idx.blockedByOpenBase("c"), "non-bottom is blocked by open base")

        // Same branch names in a DIFFERENT repo must not link across repos.
        let x = make("x", number: 1, repo: "o/other", head: "feat/a", base: "main")
        let y = make("y", number: 2, repo: "o/other", head: "feat/z", base: "feat/a")
        let cross = StackEngine.detect([a, b, x, y])
        assert(cross.count == 2, "two independent stacks, one per repo — no cross-repo link")
        assert(cross.allSatisfy { Set($0.members.map(\.repoFullName)).count == 1 },
               "every stack is single-repo")

        // A merged bottom breaks the link: the child is retargeted, so it stands alone.
        let mergedBottom = make("a", number: 1, head: "feat/a", base: "main", merged: true)
        let orphan = make("b", number: 2, head: "feat/b", base: "feat/a")
        assert(StackEngine.detect([mergedBottom, orphan]).isEmpty,
               "merged base is not a live link → child is standalone, no stack")

        // A fork (one base, two children) is a single stack (connected component).
        let d = make("d", number: 4, head: "feat/d", base: "feat/a")
        let forked = StackEngine.detect([a, b, d])
        assert(forked.count == 1 && forked[0].count == 3, "forked stack is one component of three")
        assert(forked[0].bottom.nodeId == "a", "fork root is the shared base")

        // Two totally unrelated PRs → no stack.
        let lone1 = make("l1", number: 1, head: "feat/1", base: "main")
        let lone2 = make("l2", number: 2, head: "feat/2", base: "main")
        assert(StackEngine.detect([lone1, lone2]).isEmpty, "unrelated PRs form no stack")
    }
}
#endif
