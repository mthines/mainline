import Foundation
import UserNotifications

/// Fires native macOS notifications for PR transitions.
/// Each notification uses a deterministic identifier to prevent duplicate banners.
final class NotificationService {

    // MARK: - Category & Action

    static let categoryId       = "PERCH_PR"
    static let openActionId     = "OPEN_IN_BROWSER"

    // MARK: - Request permission

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[Perch] Notification auth error: \(error.localizedDescription)")
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

    /// Fires one notification per transition, respecting the notification toggles.
    func fireTransitions(_ transitions: [PRTransition], settings: PerchSettings) {
        for transition in transitions {
            switch transition {
            case .newPR(let pr):
                guard settings.notifyNewPR else { continue }
                fire(
                    id:    "perch.new_pr.\(pr.nodeId)",
                    title: "New PR",
                    body:  "\(pr.repoFullName): \(pr.title)",
                    url:   pr.htmlUrl
                )

            case .readyForReview(let pr):
                guard settings.notifyReadyForReview else { continue }
                fire(
                    id:    "perch.ready.\(pr.nodeId)",
                    title: "Ready for Review",
                    body:  "\(pr.repoFullName): \(pr.title)",
                    url:   pr.htmlUrl
                )

            case .ciStatusChanged(let pr, _, let to):
                guard settings.notifyCIChange else { continue }
                fire(
                    id:    "perch.ci.\(pr.nodeId)",
                    title: "CI Status Changed",
                    body:  "\(pr.repoFullName): \(pr.title) — \(to.rawValue)",
                    url:   pr.htmlUrl
                )

            case .newReviewOrComment(let pr):
                guard settings.notifyReviewComment else { continue }
                fire(
                    id:    "perch.comment.\(pr.nodeId)",
                    title: "New Review/Comment",
                    body:  "\(pr.repoFullName): \(pr.title)",
                    url:   pr.htmlUrl
                )
            }
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
                print("[Perch] Failed to deliver notification '\(id)': \(error.localizedDescription)")
            }
        }
    }
}
