import Foundation
import Combine

// MARK: - PRScope

/// An org-level or repo-level scope derived from `repoFullName`.
enum PRScope: Hashable, Codable {
    case org(String)    // "dash0hq"
    case repo(String)   // "dash0hq/opentelemetry-dotnet"

    var displayName: String {
        switch self {
        case .org(let o):  return o
        case .repo(let r): return r
        }
    }

    var rawValue: String {
        switch self {
        case .org(let o):  return "org:\(o)"
        case .repo(let r): return "repo:\(r)"
        }
    }

    static func from(rawValue: String) -> PRScope? {
        if rawValue.hasPrefix("org:") {
            return .org(String(rawValue.dropFirst(4)))
        } else if rawValue.hasPrefix("repo:") {
            return .repo(String(rawValue.dropFirst(5)))
        }
        return nil
    }
}

// MARK: - ScopeStore

/// @MainActor store that derives available scopes from the current PR list.
/// Rebuilds after each poll; persists the selected scope across launches.
@MainActor
final class ScopeStore: ObservableObject {

    /// Currently selected scope. nil = "All".
    @Published var selectedScope: PRScope? = nil {
        didSet { persist() }
    }

    /// All available org-level scopes, ordered by count descending.
    @Published private(set) var availableScopes: [PRScope] = []

    /// Count per scope for the most recent rebuild call.
    @Published private(set) var scopeCounts: [PRScope: Int] = [:]

    private let defaults = UserDefaults.standard
    private static let selectedScopeKey = "selectedScope2"

    init() {
        restore()
    }

    // MARK: - Rebuild

    /// Derive available scopes and counts from the current PR list.
    /// Call after every poll to keep counts fresh.
    func rebuild(from prs: [PRSnapshot]) {
        var counts: [PRScope: Int] = [:]
        for pr in prs {
            let parts = pr.repoFullName.split(separator: "/", maxSplits: 1)
            guard let owner = parts.first.map(String.init) else { continue }
            let orgScope = PRScope.org(owner)
            counts[orgScope, default: 0] += 1
        }

        // Sort by count descending, then name ascending
        let sorted = counts.keys.sorted {
            let c1 = counts[$0] ?? 0
            let c2 = counts[$1] ?? 0
            if c1 != c2 { return c1 > c2 }
            return $0.displayName < $1.displayName
        }

        availableScopes = sorted
        scopeCounts = counts

        // Invalidate selectedScope only when the derived list is non-empty AND
        // genuinely lacks the selection. An early launch poll can call rebuild
        // with an empty/partial PR list (sorted == []); nulling then would wipe
        // the user's persisted choice before it can ever match. Guard on
        // non-empty so we never null while the list is still loading.
        if !sorted.isEmpty, let sel = selectedScope, !sorted.contains(sel) {
            selectedScope = nil
        }
    }

    // MARK: - Persistence

    func persist() {
        defaults.set(selectedScope?.rawValue, forKey: Self.selectedScopeKey)
    }

    func restore() {
        guard let raw = defaults.string(forKey: Self.selectedScopeKey) else { return }
        selectedScope = PRScope.from(rawValue: raw)
    }
}
