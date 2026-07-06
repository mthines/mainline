import Foundation

// MARK: - SnoozeStore

/// @MainActor thin wrapper over `MainlineSettings.snoozeMap`.
/// Provides a typed API for snoozing PRs and checking snooze status.
/// Snooze is transient user intent — stored in UserDefaults, not a durable file.
@MainActor
final class SnoozeStore {

    // MARK: - Dependencies

    private let settings: MainlineSettings

    // MARK: - Init

    init(settings: MainlineSettings = .shared) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Snoozes a PR until the given date.
    func snooze(_ pr: PRSnapshot, until wakeTime: Date) {
        var map = settings.snoozeMap
        map[pr.nodeId] = wakeTime
        settings.snoozeMap = map
    }

    /// Returns true if the PR is currently snoozed (wake time is in the future).
    func isSnoozed(_ pr: PRSnapshot) -> Bool {
        guard let wakeTime = settings.snoozeMap[pr.nodeId] else { return false }
        return wakeTime > Date()
    }

    /// Removes all expired snooze entries (wake time in the past).
    /// Call this on panel open to keep the map clean.
    func clearExpired() {
        let now = Date()
        var map = settings.snoozeMap
        map = map.filter { $0.value > now }
        settings.snoozeMap = map
    }

    /// Returns the wake-up date for a snoozed PR, or nil if not snoozed / expired.
    func wakeTime(for pr: PRSnapshot) -> Date? {
        guard let date = settings.snoozeMap[pr.nodeId], date > Date() else { return nil }
        return date
    }
}
