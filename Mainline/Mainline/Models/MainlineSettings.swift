import Foundation
import Combine

/// All non-secret app settings backed by UserDefaults.
final class MainlineSettings: ObservableObject {
    static let shared = MainlineSettings()

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
        // Triage Cockpit additions
        static let writeActionsEnabled  = "writeActionsEnabled"
        static let autopilotEnabled     = "autopilotEnabled"
        static let collapsedSectionsRaw = "collapsedSectionsRaw"
        static let snoozeMapData        = "snoozeMapData"
        static let attentionPolicy      = "attentionPolicy"
        static let unreadPRIds          = "unreadPRIds"
        static let panelHeight          = "panelHeight"
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

    // MARK: - Triage Cockpit settings

    /// Whether write actions (Approve, Merge, Request Changes) are enabled. Default OFF.
    @Published var writeActionsEnabled: Bool {
        didSet { defaults.set(writeActionsEnabled, forKey: Keys.writeActionsEnabled) }
    }

    /// Whether autopilot auto-approve is active. Requires writeActionsEnabled. Default OFF.
    @Published var autopilotEnabled: Bool {
        didSet { defaults.set(autopilotEnabled, forKey: Keys.autopilotEnabled) }
    }

    /// Section raw values that are collapsed. Stored as [String] in UserDefaults.
    @Published var collapsedSectionsRaw: [String] {
        didSet { defaults.set(collapsedSectionsRaw, forKey: Keys.collapsedSectionsRaw) }
    }

    /// Typed accessor for collapsed sections.
    var collapsedSections: Set<PRState> {
        get { Set(collapsedSectionsRaw.compactMap { PRState(rawValue: $0) }) }
        set { collapsedSectionsRaw = newValue.map { $0.rawValue } }
    }

    /// Per-event attention policy: [PREvent.rawValue: AttentionLevel.rawValue].
    /// Defaults to `PREvent.defaults` when a key is absent.
    @Published var attentionPolicy: [String: String] {
        didSet { defaults.set(attentionPolicy, forKey: Keys.attentionPolicy) }
    }

    /// PRs the user hasn't looked at yet (persisted nodeIds).
    @Published var unreadPRIdsList: [String] {
        didSet { defaults.set(unreadPRIdsList, forKey: Keys.unreadPRIds) }
    }

    /// Preferred panel content height. Options: 400/480/560/640. Default 560.
    @Published var panelHeight: Int {
        didSet { defaults.set(panelHeight, forKey: Keys.panelHeight) }
    }

    /// Snooze map: PR nodeId → wake time. Serialized as JSON data in UserDefaults.
    @Published var snoozeMap: [String: Date] {
        didSet {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snoozeMap) {
                defaults.set(data, forKey: Keys.snoozeMapData)
            }
        }
    }

    // MARK: - Attention policy helper

    /// Returns the attention level for a given event, falling back to the default.
    func level(for event: PREvent) -> AttentionLevel {
        if let raw = attentionPolicy[event.rawValue],
           let level = AttentionLevel(rawValue: raw) {
            return level
        }
        return PREvent.defaults[event] ?? .notify
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

        // Triage Cockpit — default OFF for write actions and autopilot
        writeActionsEnabled = defaults.bool(forKey: Keys.writeActionsEnabled)
        autopilotEnabled    = defaults.bool(forKey: Keys.autopilotEnabled)

        // Collapsed sections — default: none collapsed
        collapsedSectionsRaw = defaults.stringArray(forKey: Keys.collapsedSectionsRaw) ?? []

        // Attention policy — defaults are baked into PREvent.defaults
        attentionPolicy = defaults.dictionary(forKey: Keys.attentionPolicy) as? [String: String] ?? [:]
        unreadPRIdsList = defaults.stringArray(forKey: Keys.unreadPRIds) ?? []
        panelHeight     = defaults.object(forKey: Keys.panelHeight) == nil ? 560 : defaults.integer(forKey: Keys.panelHeight)

        // Snooze map — decode from JSON data; default empty
        if let data = defaults.data(forKey: Keys.snoozeMapData) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snoozeMap = (try? decoder.decode([String: Date].self, from: data)) ?? [:]
        } else {
            snoozeMap = [:]
        }
    }
}
