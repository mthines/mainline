import Foundation
import UserNotifications
import AppKit

// MARK: - NotificationAuthorizationState

/// Whether the app can actually put a banner on screen right now.
///
/// The distinction that matters to the user is NOT `authorizationStatus` alone:
/// an app can be fully authorized and still show nothing because the alert style
/// is set to "None" in System Settings. Both suppress every banner, and before
/// this existed neither was read anywhere in the app — `requestAuthorization`
/// discarded its `granted` flag and the only trace of a failed delivery was a
/// `print` to stdout, so "I checked the setting and still got nothing" had no
/// visible explanation.
enum NotificationAuthorizationState: Equatable {
    /// Authorized and an alert style is set — banners will be delivered.
    case authorized
    /// Authorized, but alerts are turned off (style "None" or alerts disabled).
    /// Badge/sound may still work; no banner will ever appear.
    case silent
    /// The user denied notifications. Every `add()` fails.
    case denied
    /// The prompt has not been answered yet (or was dismissed).
    case notDetermined
    /// Not yet read, or an unrecognized status.
    case unknown

    /// Whether a banner can actually reach the user in this state.
    var canDeliverBanners: Bool { self == .authorized }

    /// Short user-facing explanation, or `nil` when delivery works.
    var warningText: String? {
        switch self {
        case .authorized:
            return nil
        case .silent:
            return "Notifications are allowed, but Mainline's alert style is set to \"None\", so no banners appear. Set it to Banners or Alerts in System Settings."
        case .denied:
            return "macOS is blocking Mainline's notifications. No banner will appear until you allow them in System Settings, no matter how the events below are configured."
        case .notDetermined:
            return "Mainline hasn't been granted permission to send notifications yet. Allow them in System Settings to start receiving banners."
        case .unknown:
            return nil
        }
    }
}

/// Fires native macOS notifications for PR transitions.
/// Each notification uses a deterministic identifier to prevent duplicate banners.
final class NotificationService {

    // MARK: - Category & Action

    static let categoryId       = "MAINLINE_PR"
    static let openActionId     = "OPEN_IN_BROWSER"

    // MARK: - Request permission

    /// Requests authorization and registers the notification category.
    ///
    /// Async so the caller can await the user's answer and then read
    /// `authorizationState()` — the `granted` flag used to be discarded, which is
    /// why a denied prompt left the app with no idea it could never deliver.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let openAction = UNNotificationAction(
            identifier: Self.openActionId,
            title: "Open in Browser",
            options: .foreground
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])

        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        print("[Mainline] Notification auth error: \(error.localizedDescription)")
                    }
                    if !granted {
                        print("[Mainline] Notification authorization NOT granted — banners will not be delivered.")
                    }
                    continuation.resume(returning: granted)
                }
        }
    }

    // MARK: - Authorization status

    /// Reads the current notification settings and classifies whether banners can
    /// actually be delivered.
    ///
    /// Uses the completion-handler `getNotificationSettings` wrapped in a
    /// continuation rather than the `async` accessor, so availability is
    /// unambiguous on the macOS 13.0 deployment target.
    func authorizationState() async -> NotificationAuthorizationState {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: Self.classify(
                    authorizationStatus: settings.authorizationStatus,
                    alertStyle: settings.alertStyle,
                    alertSetting: settings.alertSetting
                ))
            }
        }
    }

    /// Pure classification of the three settings that decide banner delivery.
    ///
    /// Separated from the async read so the decision table is assertable without
    /// the notification framework (see `NotificationRoutingChecks`). `.provisional`
    /// is treated as authorized. The status switch keeps a `default` branch rather
    /// than being exhaustive: `UNAuthorizationStatus` is a platform enum whose
    /// cases differ by OS, so a `default` is both safe and portable.
    static func classify(
        authorizationStatus: UNAuthorizationStatus,
        alertStyle: UNAlertStyle,
        alertSetting: UNNotificationSetting
    ) -> NotificationAuthorizationState {
        switch authorizationStatus {
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional:
            // Authorized but muted: either alerts are explicitly disabled or the
            // style is "None". Both mean no banner ever reaches the screen.
            if alertSetting == UNNotificationSetting.disabled { return .silent }
            if alertStyle == UNAlertStyle.none { return .silent }
            return .authorized
        default:
            return .unknown
        }
    }

    /// Opens System Settings on the Notifications pane so the user can fix a
    /// `denied` / `silent` state without hunting for it. macOS 13+ pane anchor.
    static func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Fire transitions

    /// Fires notifications per the per-event attention policy.
    ///
    /// Returns the nodeIds of events processed at `.quiet` level. This is
    /// informational only and is NOT how unread is derived: the sole caller
    /// (`PRPoller.poll`) discards this value and marks EVERY surviving
    /// transition unread, so `.notify`, `.quiet` and `.off` all light the unread
    /// dot. Changing an event's attention level therefore changes whether a
    /// banner appears — never whether the PR counts as unread.
    @discardableResult
    func fireTransitions(_ transitions: [PRTransition], settings: MainlineSettings, myLogin: String = "") -> [String] {
        var quietNodeIds: [String] = []

        for transition in transitions {
            guard let (event, pr, notifArgs) = resolveTransition(transition, myLogin: myLogin)
            else { continue }

            let level = settings.level(for: event)
            switch level {
            case .off:
                continue
            case .quiet:
                quietNodeIds.append(pr.nodeId)
                TelemetryService.shared.recordNotificationFired(
                    eventType: event.rawValue,
                    attentionLevel: "quiet"
                )
            case .notify:
                fire(id: notifArgs.id, title: notifArgs.title, body: notifArgs.body, url: notifArgs.url)
                TelemetryService.shared.recordNotificationFired(
                    eventType: event.rawValue,
                    attentionLevel: "notify"
                )
            }
        }

        return quietNodeIds
    }

    /// Resolve a transition into an event + notification args tuple.
    /// Returns nil when no event should fire (e.g., someone else's CI change).
    ///
    /// Deliberately `internal` rather than `private` so `NotificationRoutingChecks`
    /// can assert the routing table directly — the `.newPR` and `.ciStatusChanged`
    /// branches are exactly where notification delivery was silently lost.
    func resolveTransition(
        _ transition: PRTransition,
        myLogin: String
    ) -> (PREvent, PRSnapshot, (id: String, title: String, body: String, url: String))? {
        switch transition {
        case .newPR(let pr):
            let event: PREvent
            let title: String
            // Case-insensitive: GitHub logins are, and a stored `MThines` against
            // the API's `mthines` used to demote your own PR to the review path.
            if PRSnapshot.loginsMatch(pr.author, myLogin) {
                event = .newPRByMe
                title = "New PR"
            } else if pr.reviewRequestSource(myLogin: myLogin) == .team {
                // Team pulled this into the For-me set — quiet by default.
                event = .reviewRequestedTeam
                title = "Team review requested"
            } else {
                // Every other new PR — including a direct review request. Defaults
                // to `.notify`; it used to be `.quiet`, which made "New PR"
                // banners unreachable for anything you didn't author yourself.
                event = .reviewRequested
                title = "New PR"
            }
            let args = (id: "mainline.new_pr.\(pr.nodeId)", title: title,
                        body: "\(pr.repoFullName): \(pr.title)", url: pr.htmlUrl)
            return (event, pr, args)
        case .readyForReview(let pr):
            let event: PREvent = (pr.isDraft == false) ? .readyForReview : .draftCreated
            let args = (id: "mainline.ready.\(pr.nodeId)", title: "Ready for Review",
                        body: "\(pr.repoFullName): \(pr.title)", url: pr.htmlUrl)
            return (event, pr, args)
        case .ciStatusChanged(let pr, _, let to):
            // CI changes only matter on your OWN PRs. Case-insensitive, and an
            // empty `myLogin` still matches nobody — but note that an empty login
            // therefore silences CI notifications entirely, which is why
            // `PRManager.start()` now self-heals `githubUsername`.
            guard PRSnapshot.loginsMatch(pr.author, myLogin) else { return nil }
            let event: PREvent = (to == .success) ? .ciPassedOnMyPR : .ciFailedOnMyPR
            let args = (id: "mainline.ci.\(pr.nodeId)", title: "CI Status Changed",
                        body: "\(pr.repoFullName): \(pr.title) — \(to.rawValue)", url: pr.htmlUrl)
            return (event, pr, args)
        case .newReviewOrComment(let pr):
            let args = (id: "mainline.comment.\(pr.nodeId)", title: "New Review/Comment",
                        body: "\(pr.repoFullName): \(pr.title)", url: pr.htmlUrl)
            return (.newReviewOrComment, pr, args)
        }
    }

    // MARK: - Private

    private func fire(id: String, title: String, body: String, url: String) {
        let content = UNMutableNotificationContent()
        content.title             = title
        content.body              = body
        content.sound             = .default
        content.categoryIdentifier = Self.categoryId
        content.userInfo          = ["url": url]

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                // Almost always an authorization problem. Settings → Notifications
                // surfaces the state; this log is the developer-side breadcrumb.
                print("[Mainline] Failed to deliver notification '\(id)': \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Notification routing self-checks (DEBUG)

#if DEBUG
/// Lightweight, dependency-free assertions for the two pure decision tables in
/// this file: how a `PRTransition` maps to a `PREvent` (`resolveTransition`) and
/// how notification settings map to a delivery verdict (`classify`). Mirrors
/// `InboxMuteEngine.runSelfChecks()` — invoked once at launch so a regression
/// trips an assertion in a debug build without a full XCTest target.
enum NotificationRoutingChecks {
    private static func pr(author: String, teams: [String] = []) -> PRSnapshot {
        PRSnapshot(
            nodeId: "n", number: 1, title: "t", htmlUrl: "u", repoFullName: "o/r",
            isDraft: false, state: "open", ciStatus: .success, reviewState: .none,
            commentCount: 0, updatedAt: "", author: author,
            requestedReviewers: [], requestedTeams: teams
        )
    }

    static func run() {
        let service = NotificationService()
        let me = "MThines"   // deliberately cased differently from the API value

        func event(_ transition: PRTransition) -> PREvent? {
            service.resolveTransition(transition, myLogin: me)?.0
        }

        // MARK: .newPR routing
        // Your own PR, case-mismatched login → authored event (used to fall
        // through to the quiet review path whenever the case differed).
        assert(event(.newPR(pr(author: "mthines"))) == .newPRByMe,
               "case-mismatched own PR → newPRByMe")
        // Someone else's PR with no team request → reviewRequested (now .notify).
        assert(event(.newPR(pr(author: "someone"))) == .reviewRequested,
               "someone else's new PR → reviewRequested")
        // A team request routes to the quieter team event.
        assert(event(.newPR(pr(author: "someone", teams: ["ai"]))) == .reviewRequestedTeam,
               "team-requested new PR → reviewRequestedTeam")
        // With an unknown viewer, your own PR can't be recognized as yours.
        assert(service.resolveTransition(.newPR(pr(author: "mthines")), myLogin: "")?.0 == .reviewRequested,
               "empty login cannot claim authorship")

        // MARK: .ciStatusChanged routing
        // Own PR, case-mismatched → fires. This is the branch an empty or
        // wrongly-cased githubUsername silenced completely.
        assert(event(.ciStatusChanged(pr(author: "mthines"), from: .pending, to: .success)) == .ciPassedOnMyPR,
               "case-mismatched own PR CI success → ciPassedOnMyPR")
        assert(event(.ciStatusChanged(pr(author: "mthines"), from: .success, to: .failure)) == .ciFailedOnMyPR,
               "case-mismatched own PR CI failure → ciFailedOnMyPR")
        // Someone else's CI is not your business.
        assert(service.resolveTransition(
            .ciStatusChanged(pr(author: "someone"), from: .pending, to: .success), myLogin: me) == nil,
               "someone else's CI change → no event")
        // Unknown viewer → no CI event at all.
        assert(service.resolveTransition(
            .ciStatusChanged(pr(author: "mthines"), from: .pending, to: .success), myLogin: "") == nil,
               "empty login → no CI event")

        // MARK: draft vs ready routing (unchanged, pinned against regression)
        assert(event(.readyForReview(pr(author: "someone"))) == .readyForReview,
               "non-draft readyForReview → readyForReview")
        assert(event(.newReviewOrComment(pr(author: "someone"))) == .newReviewOrComment,
               "comment transition → newReviewOrComment")

        // MARK: Authorization classification
        assert(NotificationService.classify(
            authorizationStatus: .authorized, alertStyle: .banner, alertSetting: .enabled) == .authorized,
               "authorized + banner → authorized")
        assert(NotificationService.classify(
            authorizationStatus: .authorized, alertStyle: .alert, alertSetting: .enabled) == .authorized,
               "authorized + alert → authorized")
        // Authorized but muted — the case that makes "I checked the box" fail.
        assert(NotificationService.classify(
            authorizationStatus: .authorized, alertStyle: UNAlertStyle.none, alertSetting: .enabled) == .silent,
               "alert style None → silent")
        assert(NotificationService.classify(
            authorizationStatus: .authorized, alertStyle: .banner, alertSetting: .disabled) == .silent,
               "alerts disabled → silent")
        assert(NotificationService.classify(
            authorizationStatus: .denied, alertStyle: .banner, alertSetting: .enabled) == .denied,
               "denied → denied")
        assert(NotificationService.classify(
            authorizationStatus: .notDetermined, alertStyle: UNAlertStyle.none, alertSetting: .notSupported) == .notDetermined,
               "notDetermined → notDetermined")

        // Only `.authorized` promises a banner; every other state warns.
        assert(NotificationAuthorizationState.authorized.canDeliverBanners,
               "authorized delivers banners")
        assert(NotificationAuthorizationState.authorized.warningText == nil,
               "authorized has no warning")
        for state in [NotificationAuthorizationState.silent, .denied, .notDetermined] {
            assert(!state.canDeliverBanners, "\(state) must not claim banner delivery")
            assert(state.warningText != nil, "\(state) must carry a user-facing warning")
        }
    }
}
#endif
