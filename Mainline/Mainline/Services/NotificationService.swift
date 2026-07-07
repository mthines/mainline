import Foundation
import UserNotifications

/// Fires native macOS notifications for PR transitions.
/// Each notification uses a deterministic identifier to prevent duplicate banners.
final class NotificationService {

    // MARK: - Category & Action

    static let categoryId       = "MAINLINE_PR"
    static let openActionId     = "OPEN_IN_BROWSER"

    // MARK: - Request permission

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[Mainline] Notification auth error: \(error.localizedDescription)")
            }
        }

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
    }

    // MARK: - Fire transitions

    /// Fires notifications per the per-event attention policy.
    /// Returns the nodeIds of events processed at `.quiet` level —
    /// these should be added to unread without a banner.
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
    private func resolveTransition(
        _ transition: PRTransition,
        myLogin: String
    ) -> (PREvent, PRSnapshot, (id: String, title: String, body: String, url: String))? {
        switch transition {
        case .newPR(let pr):
            let event: PREvent
            let title: String
            if !myLogin.isEmpty && pr.author == myLogin {
                event = .newPRByMe
                title = "New PR"
            } else if pr.reviewRequestSource(myLogin: myLogin) == .team {
                // Team pulled this into the For-me set — quiet by default.
                event = .reviewRequestedTeam
                title = "Team review requested"
            } else {
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
            guard !myLogin.isEmpty, pr.author == myLogin else { return nil }
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
                print("[Mainline] Failed to deliver notification '\(id)': \(error.localizedDescription)")
            }
        }
    }
}
