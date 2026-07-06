import Foundation
import Combine

/// All non-secret app settings backed by UserDefaults.
final class PerchSettings: ObservableObject {
    static let shared = PerchSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let pollIntervalSeconds  = "pollIntervalSeconds"
        static let searchQueryAuthor    = "searchQueryAuthor"
        static let searchQueryReviewer  = "searchQueryReviewer"
        static let notifyNewPR          = "notifyNewPR"
        static let notifyReadyForReview = "notifyReadyForReview"
        static let notifyCIChange       = "notifyCIChange"
        static let notifyReviewComment  = "notifyReviewComment"
        static let githubUsername       = "githubUsername"
        static let selectedTab          = "selectedTab"
    }

    // MARK: - Persisted properties

    @Published var pollIntervalSeconds: Int {
        didSet { defaults.set(pollIntervalSeconds, forKey: Keys.pollIntervalSeconds) }
    }

    @Published var searchQueryAuthor: String {
        didSet { defaults.set(searchQueryAuthor, forKey: Keys.searchQueryAuthor) }
    }

    @Published var searchQueryReviewer: String {
        didSet { defaults.set(searchQueryReviewer, forKey: Keys.searchQueryReviewer) }
    }

    @Published var notifyNewPR: Bool {
        didSet { defaults.set(notifyNewPR, forKey: Keys.notifyNewPR) }
    }

    @Published var notifyReadyForReview: Bool {
        didSet { defaults.set(notifyReadyForReview, forKey: Keys.notifyReadyForReview) }
    }

    @Published var notifyCIChange: Bool {
        didSet { defaults.set(notifyCIChange, forKey: Keys.notifyCIChange) }
    }

    @Published var notifyReviewComment: Bool {
        didSet { defaults.set(notifyReviewComment, forKey: Keys.notifyReviewComment) }
    }

    @Published var githubUsername: String {
        didSet { defaults.set(githubUsername, forKey: Keys.githubUsername) }
    }

    /// Last-selected Reviews tab ("For me" / "Created").
    @Published var selectedTab: ReviewTab {
        didSet { defaults.set(selectedTab.rawValue, forKey: Keys.selectedTab) }
    }

    // MARK: - ETag helpers

    func etag(for url: String) -> String? {
        defaults.string(forKey: "etag_\(url)")
    }

    func setEtag(_ etag: String, for url: String) {
        defaults.set(etag, forKey: "etag_\(url)")
    }

    // MARK: - Init

    private init() {
        // Poll interval — default 60s
        if defaults.object(forKey: Keys.pollIntervalSeconds) == nil {
            defaults.set(60, forKey: Keys.pollIntervalSeconds)
        }
        pollIntervalSeconds = defaults.integer(forKey: Keys.pollIntervalSeconds)

        // Search queries
        if defaults.object(forKey: Keys.searchQueryAuthor) == nil {
            defaults.set("is:open is:pr author:@me", forKey: Keys.searchQueryAuthor)
        }
        searchQueryAuthor = defaults.string(forKey: Keys.searchQueryAuthor) ?? "is:open is:pr author:@me"

        if defaults.object(forKey: Keys.searchQueryReviewer) == nil {
            defaults.set("is:open is:pr review-requested:@me", forKey: Keys.searchQueryReviewer)
        }
        searchQueryReviewer = defaults.string(forKey: Keys.searchQueryReviewer) ?? "is:open is:pr review-requested:@me"

        // Notification toggles — default true for all
        notifyNewPR          = defaults.object(forKey: Keys.notifyNewPR) == nil          ? true : defaults.bool(forKey: Keys.notifyNewPR)
        notifyReadyForReview = defaults.object(forKey: Keys.notifyReadyForReview) == nil ? true : defaults.bool(forKey: Keys.notifyReadyForReview)
        notifyCIChange       = defaults.object(forKey: Keys.notifyCIChange) == nil       ? true : defaults.bool(forKey: Keys.notifyCIChange)
        notifyReviewComment  = defaults.object(forKey: Keys.notifyReviewComment) == nil  ? true : defaults.bool(forKey: Keys.notifyReviewComment)

        githubUsername = defaults.string(forKey: Keys.githubUsername) ?? ""

        // Selected tab — default "For me"
        selectedTab = defaults.string(forKey: Keys.selectedTab)
            .flatMap { ReviewTab(rawValue: $0) } ?? .forMe
    }
}
