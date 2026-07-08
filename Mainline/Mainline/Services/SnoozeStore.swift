import Foundation

// MARK: - SnoozeDuration

/// The fixed set of "Later" durations offered in the row clock menu and the
/// command palette. Each case carries a display title and the `TimeInterval` it
/// adds to `Date()` to compute the wake time.
enum SnoozeDuration: String, CaseIterable, Identifiable {
    case oneHour
    case fourHours
    case oneDay
    case oneWeek

    var id: String { rawValue }

    /// Menu / palette label.
    var title: String {
        switch self {
        case .oneHour:   return "1 hour"
        case .fourHours: return "4 hours"
        case .oneDay:    return "1 day"
        case .oneWeek:   return "1 week"
        }
    }

    /// Seconds added to `Date()` to produce the wake time.
    var interval: TimeInterval {
        switch self {
        case .oneHour:   return 3600
        case .fourHours: return 4 * 3600
        case .oneDay:    return 24 * 3600
        case .oneWeek:   return 7 * 24 * 3600
        }
    }

    /// The default quick-snooze used by the `S` keyboard verb.
    static let quickDefault: SnoozeDuration = .oneDay
}

// MARK: - Relative wake humanizer

/// Produces a compact "wakes in 3h" / "wakes tomorrow" style label from a wake
/// date, relative to now. Kept as a free function so both the row and any future
/// caller share one formatter. Falls back to the short relative style for spans
/// the coarse buckets don't cover.
func humanizedWake(from wakeTime: Date, now: Date = Date()) -> String {
    let seconds = wakeTime.timeIntervalSince(now)
    guard seconds > 0 else { return "waking" }

    let minutes = Int(seconds / 60)
    let hours = Int(seconds / 3600)
    let days = Int(seconds / 86_400)

    if minutes < 60 {
        let m = max(minutes, 1)
        return "wakes in \(m)m"
    }
    if hours < 24 {
        return "wakes in \(hours)h"
    }
    if days == 1 {
        return "wakes tomorrow"
    }
    if days < 7 {
        return "wakes in \(days)d"
    }
    let weeks = days / 7
    return "wakes in \(weeks)w"
}

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
        snooze(nodeId: pr.nodeId, until: wakeTime)
    }

    /// Snoozes a PR (by nodeId) for the given duration from now.
    func snooze(nodeId: String, for duration: SnoozeDuration) {
        snooze(nodeId: nodeId, until: Date().addingTimeInterval(duration.interval))
    }

    /// Snoozes a PR (by nodeId) until the given wake time.
    ///
    /// Postponing also PERMANENTLY mutes the PR from notifications: the nodeId is
    /// added to `settings.notifMutedNodeIds`, which — unlike the snooze wake time —
    /// is never auto-cleared. So once postponed, a PR never fires a banner again,
    /// even after it wakes and returns to its normal group. `unsnooze` does NOT lift
    /// the mute (see its note).
    func snooze(nodeId: String, until wakeTime: Date) {
        var map = settings.snoozeMap
        map[nodeId] = wakeTime
        settings.snoozeMap = map

        var muted = settings.notifMutedNodeIds
        muted.insert(nodeId)
        settings.notifMutedNodeIds = muted
    }

    /// Removes a snooze entry, returning the PR to its normal group immediately.
    /// Intentionally does NOT lift the notification mute: a PR you postponed stays
    /// muted even after you resume it, matching "postponed should never notify
    /// again". Clear the mute explicitly via `unmuteNotifications` if ever needed.
    func unsnooze(nodeId: String) {
        var map = settings.snoozeMap
        map.removeValue(forKey: nodeId)
        settings.snoozeMap = map
    }

    /// Returns true if the PR has been postponed at least once and is therefore
    /// permanently muted from notifications.
    func isNotificationMuted(nodeId: String) -> Bool {
        settings.notifMutedNodeIds.contains(nodeId)
    }

    /// Lifts the permanent notification mute for a PR (escape hatch — not wired to
    /// resume, which intentionally leaves the mute in place).
    func unmuteNotifications(nodeId: String) {
        var muted = settings.notifMutedNodeIds
        muted.remove(nodeId)
        settings.notifMutedNodeIds = muted
    }

    /// The set of nodeIds currently snoozed (wake time in the future).
    var snoozedNodeIds: Set<String> {
        let now = Date()
        return Set(settings.snoozeMap.filter { $0.value > now }.keys)
    }

    /// Wake time for a nodeId, or nil if not snoozed / expired.
    func wakeTime(nodeId: String) -> Date? {
        guard let date = settings.snoozeMap[nodeId], date > Date() else { return nil }
        return date
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
