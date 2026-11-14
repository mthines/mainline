import Foundation

/// Who may see the Developer pane (and therefore set flag overrides).
///
/// The pane is visible in DEBUG builds, or when the signed-in GitHub login is on the
/// owner allowlist. This is a UI gate, not a security boundary: an override only changes
/// what this Mac renders, and a flag value never grants access to anything.
enum FeatureFlagAccess {
    /// Logins that see the Developer pane in a release build.
    static let defaultOwnerLogins = ["mthines"]

    static func isOwner(login: String, allowlist: [String]) -> Bool {
        allowlist.contains { PRSnapshot.loginsMatch($0, login) }
    }

    static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    static func developerPaneVisible(
        login: String,
        allowlist: [String],
        isDebugBuild: Bool = FeatureFlagAccess.isDebugBuild
    ) -> Bool {
        isDebugBuild || isOwner(login: login, allowlist: allowlist)
    }
}
