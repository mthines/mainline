import Foundation
import Combine
import AppKit
import Carbon.HIToolbox

// MARK: - MenuBarMetric

/// What the menu-bar badge counts. User-configurable in Settings.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case needsAHuman        // PRs in the "Needs a Human" bucket (default)
    case failingCI          // open PRs with failing/errored CI
    case reviewRequests     // PRs where the user is a requested reviewer
    case unread             // PRs the user hasn't looked at yet
    case totalOpen          // all open (non-merged, non-closed) PRs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .needsAHuman:    return "Needs attention"
        case .failingCI:      return "Failing CI"
        case .reviewRequests: return "Review Requests"
        case .unread:         return "Unread"
        case .totalOpen:      return "Total Open"
        }
    }
}

// MARK: - ForMeReviewFilter

/// Sub-filter for the "For me" tab: narrow the visible PRs by how the review
/// was requested. Default `.all` shows both direct and team requests.
enum ForMeReviewFilter: String, CaseIterable, Identifiable {
    case all
    case direct
    case team

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:    return "All"
        case .direct: return "Direct"
        case .team:   return "Team"
        }
    }
}

// MARK: - MergeMethodPreference

/// The user's preferred merge method for in-app merges. `.auto` (default) picks
/// the repo's allowed method (squash → rebase → merge); the explicit cases request
/// that method when the repo allows it, otherwise fall back to the auto order.
enum MergeMethodPreference: String, CaseIterable, Identifiable {
    case auto
    case merge
    case squash
    case rebase

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:   return "Auto"
        case .merge:  return "Merge commit"
        case .squash: return "Squash"
        case .rebase: return "Rebase"
        }
    }
}

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
        static let notifyOnlyHumanComments = "notifyOnlyHumanComments"
        static let githubUsername       = "githubUsername"
        static let selectedTab          = "selectedTab"
        // Triage Cockpit additions
        static let writeActionsEnabled  = "writeActionsEnabled"
        static let mergeMethodPreference = "mergeMethodPreference"
        static let collapsedSectionsRaw = "collapsedSectionsRaw"
        static let snoozeMapData        = "snoozeMapData"
        static let attentionPolicy      = "attentionPolicy"
        static let unreadPRIds          = "unreadPRIds"
        static let notifMutedNodeIds    = "notifMutedNodeIds"
        static let panelHeight          = "panelHeight"
        static let panelMinHeight       = "panelMinHeight"
        static let menuBarMetric        = "menuBarMetric"
        static let menuBarScopeFollows  = "menuBarScopeFollowsSelection"
        static let includeConflictsInNeedsHuman = "includeConflictsInNeedsHuman"
        static let showDrafts           = "showDrafts"
        static let splitDrafts          = "splitDrafts"
        static let forMeReviewFilter    = "forMeReviewFilter"
        static let compactRows          = "compactRows"
        static let needsHumanExpanded   = "needsHumanExpanded"
        // Global shortcut
        static let globalShortcutEnabled   = "globalShortcutEnabled"
        static let globalShortcutKeyCode   = "globalShortcutKeyCode"
        static let globalShortcutModifiers = "globalShortcutModifiers"
        // Telemetry consent
        static let telemetryEnabled                 = "telemetryEnabled"
        static let telemetryInstallationId          = "telemetryInstallationId"
        static let telemetryBannerDismissedVersion  = "telemetryBannerDismissedVersion"
        static let telemetryLastLaunchedVersion     = "telemetryLastLaunchedVersion"
    }

    // MARK: - Global shortcut defaults

    /// Virtual key code for the ISO section key (`kVK_ISO_Section`), i.e. the
    /// physical key left of "1" that produces "$" on a Danish layout.
    static let defaultShortcutKeyCode = 0x0A
    /// Default modifier mask: ⇧⌃ (shift + control).
    static let defaultShortcutModifiers: UInt = {
        NSEvent.ModifierFlags([.shift, .control]).rawValue
    }()

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

    /// When true, the "new review or comment" notification fires only for
    /// human-authored comments/reviews — bot/app activity (CodeRabbit, Vercel,
    /// dependabot, Claude review bots, etc.) is ignored. Default true.
    /// Affects notifications only; unread/badge state is unaffected.
    @Published var notifyOnlyHumanComments: Bool {
        didSet { defaults.set(notifyOnlyHumanComments, forKey: Keys.notifyOnlyHumanComments) }
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

    /// The user's preferred merge method for in-app merges. Default `.auto`.
    @Published var mergeMethodPreference: MergeMethodPreference {
        didSet { defaults.set(mergeMethodPreference.rawValue, forKey: Keys.mergeMethodPreference) }
    }

    /// Section raw values that are collapsed. Stored as [String] in UserDefaults.
    @Published var collapsedSectionsRaw: [String] {
        didSet { defaults.set(collapsedSectionsRaw, forKey: Keys.collapsedSectionsRaw) }
    }

    /// Typed accessor for collapsed sections, keyed by the actionability
    /// `ActionGroup`. Old stored values keyed by the legacy `PRState` raw strings
    /// (e.g. "open", "inReview", "approved") simply don't decode to any
    /// `ActionGroup` case and are silently dropped — the affected sections start
    /// expanded, which is the intended migration fallback (no crash on old data).
    var collapsedSections: Set<ActionGroup> {
        get { Set(collapsedSectionsRaw.compactMap { ActionGroup(rawValue: $0) }) }
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

    /// PRs the user has postponed at least once — permanently muted from
    /// notifications. Postponing a PR is a signal of "I've dealt with this, stop
    /// telling me about it", so the mute must OUTLIVE the snooze window: unlike
    /// `snoozeMap` (transient wake times, pruned by `clearExpired`), this set is
    /// never auto-cleared, so a postponed PR never fires a banner again — even after
    /// it wakes and returns to its normal group. Persisted as a nodeId list.
    @Published var notifMutedNodeIdsList: [String] {
        didSet { defaults.set(notifMutedNodeIdsList, forKey: Keys.notifMutedNodeIds) }
    }

    /// Set view over `notifMutedNodeIdsList` for membership checks and inserts.
    var notifMutedNodeIds: Set<String> {
        get { Set(notifMutedNodeIdsList) }
        set { notifMutedNodeIdsList = Array(newValue) }
    }

    /// Preferred MAX panel content height. The panel sizes to content and grows up
    /// to this (capped to the display). Default 560.
    @Published var panelHeight: Int {
        didSet { defaults.set(panelHeight, forKey: Keys.panelHeight) }
    }

    /// Preferred MIN panel content height — the panel never shrinks below this even
    /// with few PRs. Clamped not to exceed `panelHeight` downstream. Default 240.
    @Published var panelMinHeight: Int {
        didSet { defaults.set(panelMinHeight, forKey: Keys.panelMinHeight) }
    }

    /// What the menu-bar badge counts. Default `needsAHuman`.
    @Published var menuBarMetric: MenuBarMetric {
        didSet { defaults.set(menuBarMetric.rawValue, forKey: Keys.menuBarMetric) }
    }

    /// Whether the menu-bar badge follows the currently selected scope. Default true.
    @Published var menuBarScopeFollowsSelection: Bool {
        didSet { defaults.set(menuBarScopeFollowsSelection, forKey: Keys.menuBarScopeFollows) }
    }

    /// Whether merge conflicts route a PR into the "Needs a Human" bucket.
    /// Default OFF — the focus is CI health; conflicts are shown as an
    /// informational tag but do not dominate the bucket.
    @Published var includeConflictsInNeedsHuman: Bool {
        didSet { defaults.set(includeConflictsInNeedsHuman, forKey: Keys.includeConflictsInNeedsHuman) }
    }

    /// Whether draft PRs are included in the visible list, sections, counts,
    /// and the "Needs a Human" bucket. Default OFF for a calmer view.
    @Published var showDrafts: Bool {
        didSet { defaults.set(showDrafts, forKey: Keys.showDrafts) }
    }

    /// Whether shown draft PRs get their own "Draft" section. Default OFF — drafts
    /// are mixed into their real state group (Open/Approved/etc.) and stay visually
    /// distinct via the Draft badge + dimmed row. Independent of `showDrafts`
    /// (show/hide); this only controls grouping of drafts that are already shown.
    @Published var splitDrafts: Bool {
        didSet { defaults.set(splitDrafts, forKey: Keys.splitDrafts) }
    }

    /// Sub-filter for the "For me" tab. Default `.all` (show direct + team).
    @Published var forMeReviewFilter: ForMeReviewFilter {
        didSet { defaults.set(forMeReviewFilter.rawValue, forKey: Keys.forMeReviewFilter) }
    }

    /// Whether PR rows use the compact (single-line, tighter) density. Default ON
    /// so more PRs fit per screen. When off, rows use the comfortable two-line
    /// layout. Drives `RowMetrics` shared by the triage deck and Needs-a-Human rows.
    @Published var compactRows: Bool {
        didSet { defaults.set(compactRows, forKey: Keys.compactRows) }
    }

    /// LEGACY (unused): formerly whether the separate top "Needs a Human" section
    /// was expanded. That bucket was removed — the browse list's "Needs attention"
    /// group is now the single "needs attention" view — so nothing reads this. The
    /// field is retained (harmless) so an existing stored value decodes without
    /// crashing; it can be removed in a later cleanup. Default `false`.
    @Published var needsHumanExpanded: Bool {
        didSet { defaults.set(needsHumanExpanded, forKey: Keys.needsHumanExpanded) }
    }

    // MARK: - Global shortcut

    /// Whether a system-wide keyboard shortcut opens the Mainline popover. Default ON.
    @Published var globalShortcutEnabled: Bool {
        didSet { defaults.set(globalShortcutEnabled, forKey: Keys.globalShortcutEnabled) }
    }

    /// Virtual key code of the global shortcut. Default `0x23` (P).
    @Published var globalShortcutKeyCode: Int {
        didSet { defaults.set(globalShortcutKeyCode, forKey: Keys.globalShortcutKeyCode) }
    }

    /// Modifier flags for the global shortcut, stored as `NSEvent.ModifierFlags.rawValue`.
    /// Default `[.command, .shift, .control]`.
    @Published var globalShortcutModifiers: UInt {
        didSet { defaults.set(globalShortcutModifiers, forKey: Keys.globalShortcutModifiers) }
    }

    // MARK: - Telemetry consent

    /// The current telemetry consent schema version. Bump to re-surface the banner.
    static let currentTelemetryConsentVersion: Int = 1

    /// Whether the user has opted in to anonymous telemetry. Default OFF (opt-in).
    @Published var telemetryEnabled: Bool {
        didSet {
            defaults.set(telemetryEnabled, forKey: Keys.telemetryEnabled)
            if telemetryEnabled {
                TelemetryService.shared.configure()
            }
        }
    }

    /// Stable, random UUID per install — used as service.instance.id in OTel.
    var installationId: String {
        if let existing = defaults.string(forKey: Keys.telemetryInstallationId), !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString
        defaults.set(new, forKey: Keys.telemetryInstallationId)
        return new
    }

    /// The telemetry consent banner schema version the user last dismissed.
    /// When less than `currentTelemetryConsentVersion`, the banner is shown again.
    var telemetryBannerDismissedVersion: Int {
        get { defaults.integer(forKey: Keys.telemetryBannerDismissedVersion) }
        set { defaults.set(newValue, forKey: Keys.telemetryBannerDismissedVersion) }
    }

    /// Whether the banner has been dismissed for the current consent version.
    var telemetryBannerDismissed: Bool {
        telemetryBannerDismissedVersion >= Self.currentTelemetryConsentVersion
    }

    /// The app version string recorded at the previous launch.
    /// Used by TelemetryService to detect upgrades and emit "App upgraded" logs.
    var lastLaunchedVersion: String? {
        get { defaults.string(forKey: Keys.telemetryLastLaunchedVersion) }
        set { defaults.set(newValue, forKey: Keys.telemetryLastLaunchedVersion) }
    }

    /// Typed accessor for the stored modifier flags, masked to the device-
    /// independent modifier set so stray flags never leak in.
    var globalShortcutModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: globalShortcutModifiers)
            .intersection(.deviceIndependentFlagsMask)
    }

    /// Human-readable rendering of the shortcut, e.g. "⇧⌃⌘P". Modifier glyphs are
    /// emitted in the conventional Cocoa order (⌃⌥⇧⌘) followed by the key glyph.
    var globalShortcutDisplayString: String {
        var out = ""
        let flags = globalShortcutModifierFlags
        // Order chosen to match the default display "⇧⌃⌘P".
        if flags.contains(.shift)   { out += "⇧" }
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option)  { out += "⌥" }
        if flags.contains(.command) { out += "⌘" }
        out += Self.keyGlyph(for: globalShortcutKeyCode)
        return out
    }

    /// Reset the global shortcut to the default (⇧⌃ + ISO section key).
    func resetGlobalShortcutToDefault() {
        globalShortcutKeyCode   = Self.defaultShortcutKeyCode
        globalShortcutModifiers = Self.defaultShortcutModifiers
    }

    /// Human-readable rendering of the DEFAULT shortcut, derived from the same
    /// `defaultShortcutKeyCode` + `defaultShortcutModifiers` constants used by
    /// first-run init and `resetGlobalShortcutToDefault()`. Kept as the single
    /// source for UI labels so the default, the reset, and the label never drift.
    static var defaultGlobalShortcutDisplayString: String {
        var out = ""
        let flags = NSEvent.ModifierFlags(rawValue: defaultShortcutModifiers)
            .intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift)   { out += "⇧" }
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option)  { out += "⌥" }
        if flags.contains(.command) { out += "⌘" }
        out += keyGlyph(for: defaultShortcutKeyCode)
        return out
    }

    /// Map a virtual key code to a display glyph/character. Covers letters,
    /// digits, and common special keys; unknown codes fall back to "?".
    static func keyGlyph(for keyCode: Int) -> String {
        // Special (non-character) keys.
        switch keyCode {
        case 0x24: return "↩"   // Return
        case 0x30: return "⇥"   // Tab
        case 0x31: return "Space"
        case 0x33: return "⌫"   // Delete (backspace)
        case 0x35: return "⎋"   // Escape
        case 0x75: return "⌦"   // Forward delete
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x73: return "↖"   // Home
        case 0x77: return "↘"   // End
        case 0x74: return "⇞"   // Page Up
        case 0x79: return "⇟"   // Page Down
        default: break
        }
        if let c = Self.keyCodeToCharacter[keyCode] {
            return c
        }
        // Keys not in the ANSI map (e.g. the ISO section key, 0x0A) vary by
        // layout — ask the active keyboard layout for the character it emits.
        if let c = characterForCurrentLayout(keyCode: keyCode) {
            return c
        }
        return "?"
    }

    /// Translate a virtual key code to the character produced by the currently
    /// active keyboard layout (no modifiers applied). Returns nil if the layout
    /// can't be queried or the key produces no character. Used as a fallback for
    /// keys absent from the layout-independent ANSI map, so non-US physical keys
    /// (e.g. the ISO section key → "$" on Danish) render their real glyph.
    private static func characterForCurrentLayout(keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        var deadKeyState: UInt32 = 0

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                ptr,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }

        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.isEmpty ? nil : s.uppercased()
    }

    /// ANSI key code → uppercase character. Layout-independent (physical keys),
    /// which matches how the recorder captures `event.keyCode`.
    private static let keyCodeToCharacter: [Int: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x18: "=", 0x1B: "-", 0x21: "[", 0x1E: "]", 0x2A: "\\",
        0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`"
    ]

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
        // Ignore bot-authored comments by default — the user's stated intent.
        notifyOnlyHumanComments = defaults.object(forKey: Keys.notifyOnlyHumanComments) == nil ? true : defaults.bool(forKey: Keys.notifyOnlyHumanComments)

        githubUsername = defaults.string(forKey: Keys.githubUsername) ?? ""

        // Selected tab — default "Created" (your own PRs)
        selectedTab = defaults.string(forKey: Keys.selectedTab)
            .flatMap { ReviewTab(rawValue: $0) } ?? .created

        // Triage Cockpit — default OFF for write actions
        writeActionsEnabled = defaults.bool(forKey: Keys.writeActionsEnabled)

        // Merge method preference — default Auto (picks the repo's allowed method)
        mergeMethodPreference = defaults.string(forKey: Keys.mergeMethodPreference)
            .flatMap { MergeMethodPreference(rawValue: $0) } ?? .auto

        // Collapsed sections — default: Postponed + Done collapsed (low-priority
        // buckets stay folded until the user expands them).
        collapsedSectionsRaw = defaults.stringArray(forKey: Keys.collapsedSectionsRaw)
            ?? [ActionGroup.postponed.rawValue, ActionGroup.done.rawValue]

        // Attention policy — defaults are baked into PREvent.defaults
        attentionPolicy = defaults.dictionary(forKey: Keys.attentionPolicy) as? [String: String] ?? [:]
        unreadPRIdsList = defaults.stringArray(forKey: Keys.unreadPRIds) ?? []
        notifMutedNodeIdsList = defaults.stringArray(forKey: Keys.notifMutedNodeIds) ?? []
        panelHeight     = defaults.object(forKey: Keys.panelHeight) == nil ? 560 : defaults.integer(forKey: Keys.panelHeight)
        panelMinHeight  = defaults.object(forKey: Keys.panelMinHeight) == nil ? 240 : defaults.integer(forKey: Keys.panelMinHeight)

        // Menu-bar badge — default: count "Needs a Human", follow selected scope
        menuBarMetric = defaults.string(forKey: Keys.menuBarMetric)
            .flatMap { MenuBarMetric(rawValue: $0) } ?? .needsAHuman
        menuBarScopeFollowsSelection = defaults.object(forKey: Keys.menuBarScopeFollows) == nil
            ? true
            : defaults.bool(forKey: Keys.menuBarScopeFollows)

        // Needs-a-Human focus — default OFF (CI-focused, conflicts don't dominate)
        includeConflictsInNeedsHuman = defaults.bool(forKey: Keys.includeConflictsInNeedsHuman)
        // Drafts — default ON (show your drafts by default)
        showDrafts = defaults.object(forKey: Keys.showDrafts) == nil
            ? true
            : defaults.bool(forKey: Keys.showDrafts)
        // Split drafts into their own section — default OFF (mixed inline)
        splitDrafts = defaults.bool(forKey: Keys.splitDrafts)

        // For-me review sub-filter — default All (show direct + team)
        forMeReviewFilter = defaults.string(forKey: Keys.forMeReviewFilter)
            .flatMap { ForMeReviewFilter(rawValue: $0) } ?? .all

        // Compact rows — default ON (denser list, more PRs per screen)
        compactRows = defaults.object(forKey: Keys.compactRows) == nil
            ? true
            : defaults.bool(forKey: Keys.compactRows)

        // Needs-a-Human expanded — default collapsed (false); persisted on change
        needsHumanExpanded = defaults.bool(forKey: Keys.needsHumanExpanded)

        // Global shortcut — default ON, ⇧⌃ + ISO section key ("$" on Danish)
        globalShortcutEnabled = defaults.object(forKey: Keys.globalShortcutEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.globalShortcutEnabled)
        globalShortcutKeyCode = defaults.object(forKey: Keys.globalShortcutKeyCode) == nil
            ? Self.defaultShortcutKeyCode
            : defaults.integer(forKey: Keys.globalShortcutKeyCode)
        globalShortcutModifiers = defaults.object(forKey: Keys.globalShortcutModifiers) == nil
            ? Self.defaultShortcutModifiers
            : UInt(defaults.integer(forKey: Keys.globalShortcutModifiers))

        // Telemetry consent — default OFF (opt-in)
        telemetryEnabled = defaults.bool(forKey: Keys.telemetryEnabled)

        // Snooze map — decode from JSON data; default empty
        if let data = defaults.data(forKey: Keys.snoozeMapData) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snoozeMap = (try? decoder.decode([String: Date].self, from: data)) ?? [:]
        } else {
            snoozeMap = [:]
        }

        // Seed the notification-mute set with any PRs already postponed under the
        // old code (their snooze entries predate the mute set), so currently-
        // postponed PRs are muted immediately rather than only on the next postpone.
        // Runs after `snoozeMap` is decoded and all stored properties are set.
        if !snoozeMap.isEmpty {
            notifMutedNodeIds = notifMutedNodeIds.union(snoozeMap.keys)
        }
    }
}
