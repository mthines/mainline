import Foundation
import Combine

// MARK: - TrustLedgerStore

/// @MainActor JSON-persistence store for per-author verdict records.
/// Mirrors the `PRStateStore` / pure-shell pattern:
///   - all public methods are @MainActor
///   - JSON encode/write is dispatched to a detached task
///   - results are applied back on the main actor via `await`
@MainActor
final class TrustLedgerStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var ledger: [String: [VerdictRecord]] = [:]

    // MARK: - Persistence URL

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("com.mainline.github-pr-notifier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trust-ledger.json")
    }

    // MARK: - Max verdicts per author (prevents unbounded growth)

    private static let maxVerdictsPerAuthor = 1000

    // MARK: - Load

    /// Loads the trust ledger from disk. On missing or corrupt file, returns
    /// an empty ledger — never surfaces an error to the caller.
    func load() async {
        let url = Self.storageURL
        let result: [String: [VerdictRecord]]? = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode([String: [VerdictRecord]].self, from: data)
        }.value

        if let loaded = result {
            self.ledger = loaded
        }
        // Missing / unreadable / corrupt → stay with empty dictionary (no crash)
    }

    // MARK: - Record verdict

    /// Records a new verdict for an author and persists the updated ledger.
    func recordVerdict(_ verdict: VerdictRecord, for author: String) {
        var records = ledger[author] ?? []
        records.append(verdict)

        // Prune oldest if over the cap
        if records.count > Self.maxVerdictsPerAuthor {
            records = Array(records.suffix(Self.maxVerdictsPerAuthor))
        }

        ledger[author] = records
        persistAsync()
    }

    // MARK: - Trust tier query

    /// Returns the computed trust tier for the given author login.
    func tier(for author: String) -> TrustTier {
        let records = ledger[author] ?? []
        return TrustCalculator.tier(for: author, history: records)
    }

    // MARK: - Private persistence

    private func persistAsync() {
        let snapshot = ledger
        let url = Self.storageURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
