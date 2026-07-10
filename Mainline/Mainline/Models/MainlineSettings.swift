import Foundation
import Combine
import AppKit
import Carbon.HIToolbox

// MARK: - MenuBarMetric

/// What the menu-bar badge counts. User-configurable in Settings.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case needsAHuman        // PRs in the "Needs a Human" bucket
    case failingCI          // open PRs with failing/errored CI
    case reviewRequests     // PRs where the user is a requested reviewer
    case unread             // PRs the user hasn't looked at yet
    case totalOpen          // all open (non-merged, non-closed) PRs (default)

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

// MARK: - InAppShortcut

/// All configurable in-popover keyboard shortcuts. Each case maps to one deck
/// action. The default key assignments are baked into `InAppShortcutBindings`.
enum InAppShortcut: String, CaseIterable, Identifiable, Codable {
    case navigateDown
    case navigateUp
    case peek
    case merge
    case refresh
    case openPreview
    case snooze
    case markSeen
    case dismiss
    case multiSelectToggle
    case toggleDrafts
    case undo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .navigateDown:     return "Navigate Down"
        case .navigateUp:       return "Navigate Up"
        case .peek:             return "Peek (Space)"
        case .merge:            return "Merge PR"
        case .refresh:          return "Refresh"
        case .openPreview:      return "Open Preview"
        case .snooze:           return "Postpone"
        case .markSeen:         return "Mark Seen"
        case .dismiss:          return "Dismiss"
        case .multiSelectToggle: return "Toggle Multi-Select"
        case .toggleDrafts:     return "Toggle Drafts"
        case .undo:             return "Undo (⌘+key)"
        }
    }

    var defaultKey: String {
        switch self {
        case .navigateDown:     return "j"
        case .navigateUp:       return "k"
        case .peek:             return " "
        case .merge:            return "m"
        case .refresh:          return "r"
        case .openPreview:      return "e"   // NEW default (was "p")
        case .snooze:           return "s"
        case .markSeen:         return "n"   // NEW default (was "e")
        case .dismiss:          return "x"
        case .multiSelectToggle: return "v"
        case .toggleDrafts:     return "d"
        case .undo:             return "z"
        }
    }

    var symbolName: String {
        switch self {
        case .navigateDown:     return "arrow.down"
        case .navigateUp:       return "arrow.up"
        case .peek:             return "rectangle.stack"
        case .merge:            return "arrow.triangle.merge"
        case .refresh:          return "arrow.clockwise"
        case .openPreview:      return "globe"
        case .snooze:           return "clock"
        case .markSeen:         return "eye"
        case .dismiss:          return "xmark"
        case .multiSelectToggle: return "checkmark.circle"
        case .toggleDrafts:     return "pencil.circle"
        case .undo:             return "arrow.uturn.backward"
        }
    }
}

// MARK: - ShortcutBinding

/// A per-action binding: one base key character plus an optional modifier set.
/// Mirrors the global-hotkey storage pattern (`NSEvent.ModifierFlags.rawValue` as
/// `UInt`). Defaults to bare (no modifiers). Hashable so clash detection can key
/// on the composite (key + modifiers) instead of the bare key alone.
struct ShortcutBinding: Equatable, Hashable {
    var key: String
    /// Stored as `NSEvent.ModifierFlags.rawValue`, mirroring the global shortcut.
    var modifiers: UInt = 0

    /// Modifier flags relevant to in-app shortcuts: ⌘⇧⌃⌥ only.
    /// Caps-lock, numeric-pad, and function keys are ignored.
    static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    /// Reconstructs `NSEvent.ModifierFlags` from the stored raw value,
    /// masked to device-independent then to the relevant subset.
    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection(.deviceIndependentFlagsMask)
            .intersection(Self.relevantModifierMask)
    }
}

// Codable conformance: encode as { "key": "z", "modifiers": 256 }.
// Decode supports both the new object shape and the legacy v1.25.0 bare-string
// shape (where only the key was stored); the caller applies undo migration.
extension ShortcutBinding: Codable {
    enum CodingKeys: String, CodingKey { case key, modifiers }

    init(from decoder: Decoder) throws {
        // New-shape: {"key":"z","modifiers":256}
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        modifiers = try container.decodeIfPresent(UInt.self, forKey: .modifiers) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

// MARK: - InAppShortcutBindings

/// Codable struct holding one `ShortcutBinding` (key + modifier set) per
/// configurable in-app shortcut. Persisted as JSON in UserDefaults under
/// `shortcutBindings`. Custom `Codable` decodes BOTH the new object shape and
/// the v1.25.0 legacy bare-string shape for backward compatibility. Defaults
/// match factory assignments; undo defaults to ⌘Z (modifiers = .command).
struct InAppShortcutBindings: Equatable {
    var navigateDown:    ShortcutBinding
    var navigateUp:      ShortcutBinding
    var peek:            ShortcutBinding
    var merge:           ShortcutBinding
    var refresh:         ShortcutBinding
    var openPreview:     ShortcutBinding
    var snooze:          ShortcutBinding
    var markSeen:        ShortcutBinding
    var dismiss:         ShortcutBinding
    var multiSelectToggle: ShortcutBinding
    var toggleDrafts:    ShortcutBinding
    var undo:            ShortcutBinding

    /// Factory defaults — all bindings bare except undo = ⌘Z.
    static let defaults: InAppShortcutBindings = {
        let cmdRaw = NSEvent.ModifierFlags.command.rawValue
        return InAppShortcutBindings(
            navigateDown:    ShortcutBinding(key: "j"),
            navigateUp:      ShortcutBinding(key: "k"),
            peek:            ShortcutBinding(key: " "),
            merge:           ShortcutBinding(key: "m"),
            refresh:         ShortcutBinding(key: "r"),
            openPreview:     ShortcutBinding(key: "e"),
            snooze:          ShortcutBinding(key: "s"),
            markSeen:        ShortcutBinding(key: "n"),
            dismiss:         ShortcutBinding(key: "x"),
            multiSelectToggle: ShortcutBinding(key: "v"),
            toggleDrafts:    ShortcutBinding(key: "d"),
            undo:            ShortcutBinding(key: "z", modifiers: cmdRaw)
        )
    }()

    /// Returns the binding for a given shortcut.
    func binding(for shortcut: InAppShortcut) -> ShortcutBinding {
        switch shortcut {
        case .navigateDown:      return navigateDown
        case .navigateUp:        return navigateUp
        case .peek:              return peek
        case .merge:             return merge
        case .refresh:           return refresh
        case .openPreview:       return openPreview
        case .snooze:            return snooze
        case .markSeen:          return markSeen
        case .dismiss:           return dismiss
        case .multiSelectToggle: return multiSelectToggle
        case .toggleDrafts:      return toggleDrafts
        case .undo:              return undo
        }
    }

    /// Mutates the binding for a given shortcut.
    mutating func setBinding(_ binding: ShortcutBinding, for shortcut: InAppShortcut) {
        switch shortcut {
        case .navigateDown:      navigateDown    = binding
        case .navigateUp:        navigateUp      = binding
        case .peek:              peek            = binding
        case .merge:             merge           = binding
        case .refresh:           refresh         = binding
        case .openPreview:       openPreview     = binding
        case .snooze:            snooze          = binding
        case .markSeen:          markSeen        = binding
        case .dismiss:           dismiss         = binding
        case .multiSelectToggle: multiSelectToggle = binding
        case .toggleDrafts:      toggleDrafts    = binding
        case .undo:              undo            = binding
        }
    }

    /// Convenience shim: returns the bound key character for a shortcut.
    /// Kept for existing call sites; equivalent to `binding(for:).key`.
    func key(for shortcut: InAppShortcut) -> String {
        binding(for: shortcut).key
    }

    /// Convenience shim: updates only the key character, preserving modifiers.
    mutating func setKey(_ key: String, for shortcut: InAppShortcut) {
        var b = binding(for: shortcut)
        b.key = key
        setBinding(b, for: shortcut)
    }

    /// Returns the set of shortcuts involved in a clash. A clash is equality of
    /// BOTH the base key AND the modifier set — `E` and `⌘E` are NOT a clash;
    /// two `⌘E` bindings ARE. Shortcuts with an empty key are skipped.
    var clashingShortcuts: Set<InAppShortcut> {
        var bindingToShortcuts: [ShortcutBinding: [InAppShortcut]] = [:]
        for shortcut in InAppShortcut.allCases {
            let b = binding(for: shortcut)
            guard !b.key.isEmpty else { continue }
            bindingToShortcuts[b, default: []].append(shortcut)
        }
        var clashing = Set<InAppShortcut>()
        for (_, shortcuts) in bindingToShortcuts where shortcuts.count > 1 {
            shortcuts.forEach { clashing.insert($0) }
        }
        return clashing
    }

    /// True when no two shortcuts share the same (key + modifiers) pair.
    var isValid: Bool { clashingShortcuts.isEmpty }
}

// MARK: - InAppShortcutBindings Codable

extension InAppShortcutBindings: Codable {
    /// CodingKeys match the persisted JSON field names (unchanged from v1.25.0
    /// so existing stored data continues to decode).
    enum CodingKeys: String, CodingKey {
        case navigateDown, navigateUp, peek, merge, refresh, openPreview,
             snooze, markSeen, dismiss, multiSelectToggle, toggleDrafts, undo
    }

    /// Decode either the new `ShortcutBinding` object shape or the v1.25.0
    /// legacy bare-string shape.  Missing fields fall back to the factory
    /// default for that action.
    ///
    /// Migration rule for `undo`:
    ///   - Legacy bare-string (e.g. `"undo":"z"`) → modifiers set to `.command`
    ///     so ⌘Z behavior is preserved for v1.25.0 users.
    ///   - New object shape with explicit `modifiers` → used as-is.
    ///   - Absent entirely → factory default ⌘Z.
    init(from decoder: Decoder) throws {
        let d = InAppShortcutBindings.defaults
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cmdRaw = NSEvent.ModifierFlags.command.rawValue

        // Helper: try to decode as ShortcutBinding first; on failure try bare String.
        func decodeBinding(_ key: CodingKeys, default def: ShortcutBinding) throws -> ShortcutBinding {
            if let b = try? container.decodeIfPresent(ShortcutBinding.self, forKey: key) {
                return b
            }
            if let s = try? container.decodeIfPresent(String.self, forKey: key) {
                return ShortcutBinding(key: s.lowercased(), modifiers: 0)
            }
            return def
        }

        navigateDown    = try decodeBinding(.navigateDown,    default: d.navigateDown)
        navigateUp      = try decodeBinding(.navigateUp,      default: d.navigateUp)
        peek            = try decodeBinding(.peek,            default: d.peek)
        merge           = try decodeBinding(.merge,           default: d.merge)
        refresh         = try decodeBinding(.refresh,         default: d.refresh)
        openPreview     = try decodeBinding(.openPreview,     default: d.openPreview)
        snooze          = try decodeBinding(.snooze,          default: d.snooze)
        markSeen        = try decodeBinding(.markSeen,        default: d.markSeen)
        dismiss         = try decodeBinding(.dismiss,         default: d.dismiss)
        multiSelectToggle = try decodeBinding(.multiSelectToggle, default: d.multiSelectToggle)
        toggleDrafts    = try decodeBinding(.toggleDrafts,    default: d.toggleDrafts)

        // Undo migration: bare-string or absent → apply .command modifier.
        if let newShape = try? container.decodeIfPresent(ShortcutBinding.self, forKey: .undo) {
            // New-shape object — use modifiers as stored (trusts the encoder).
            undo = newShape
        } else if let legacyKey = try? container.decodeIfPresent(String.self, forKey: .undo) {
            // Legacy bare string (v1.25.0) → preserve the key but restore ⌘ modifier.
            undo = ShortcutBinding(key: legacyKey.lowercased(), modifiers: cmdRaw)
        } else {
            // Absent → factory default ⌘Z.
            undo = d.undo
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(navigateDown,     forKey: .navigateDown)
        try container.encode(navigateUp,       forKey: .navigateUp)
        try container.encode(peek,             forKey: .peek)
        try container.encode(merge,            forKey: .merge)
        try container.encode(refresh,          forKey: .refresh)
        try container.encode(openPreview,      forKey: .openPreview)
        try container.encode(snooze,           forKey: .snooze)
        try container.encode(markSeen,         forKey: .markSeen)
        try container.encode(dismiss,          forKey: .dismiss)
        try container.encode(multiSelectToggle, forKey: .multiSelectToggle)
        try container.encode(toggleDrafts,     forKey: .toggleDrafts)
        try container.encode(undo,             forKey: .undo)
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

/// Where the primary "open PR" action (click / ↵ / open verb) sends the user:
/// the GitHub PR page (default) or the linked Linear issue in the Linear desktop
/// app (via an `https://linear.app` universal link, which macOS routes to the
/// installed Linear app).
enum PROpenTarget: String, CaseIterable, Identifiable {
    case github
    case linear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .linear: return "Linear"
        }
    }

    /// Derives a Linear issue deep link from a PR head branch name, or `nil` when
    /// no Linear issue id can be found (or no workspace slug is configured).
    ///
    /// Relies on Linear's default git-branch format, which embeds the issue
    /// identifier — e.g. `mthines/eng-1234-fix-the-thing` → `ENG-1234`. The first
    /// `<letters>-<digits>` token in the branch is treated as the identifier. Pure
    /// (no I/O) so it is testable in isolation, matching `SensitivePathMatcher`.
    static func linearIssueURL(branch: String, workspaceSlug: String) -> URL? {
        let slug = workspaceSlug.trimmingCharacters(in: .whitespaces)
        guard !slug.isEmpty, let identifier = linearIdentifier(inBranch: branch) else { return nil }
        return URL(string: "https://linear.app/\(slug)/issue/\(identifier)")
    }

    /// Extracts the uppercased Linear issue identifier (`TEAM-123`) from a branch
    /// name, or `nil` when the branch contains no `<letters>-<digits>` token.
    static func linearIdentifier(inBranch branch: String) -> String? {
        let pattern = "[A-Za-z]{2,}-[0-9]+"
        guard let range = branch.range(of: pattern, options: .regularExpression) else { return nil }
        return branch[range].uppercased()
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
        static let prOpenTarget         = "prOpenTarget"
        static let linearWorkspaceSlug  = "linearWorkspaceSlug"
        static let defaultSnoozeDuration = "defaultSnoozeDuration"
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
        // Vercel preview detection
        static let vercelPreviewEnabled = "vercelPreviewEnabled"
        static let vercelPreviewDomains = "vercelPreviewDomains"
        // Global shortcut
        static let globalShortcutEnabled   = "globalShortcutEnabled"
        static let globalShortcutKeyCode   = "globalShortcutKeyCode"
        static let globalShortcutModifiers = "globalShortcutModifiers"
        // Telemetry consent
        static let telemetryEnabled                 = "telemetryEnabled"
        static let telemetryInstallationId          = "telemetryInstallationId"
        static let telemetryBannerDismissedVersion  = "telemetryBannerDismissedVersion"
        static let telemetryLastLaunchedVersion     = "telemetryLastLaunchedVersion"
        // In-app keyboard shortcut bindings
        static let shortcutBindings                 = "shortcutBindings"
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

    /// Where the primary "open PR" action sends the user. Default `.github`.
    @Published var prOpenTarget: PROpenTarget {
        didSet { defaults.set(prOpenTarget.rawValue, forKey: Keys.prOpenTarget) }
    }

    /// The Linear workspace URL slug (e.g. "dash0") used to build issue deep links
    /// when `prOpenTarget == .linear`. Empty disables Linear opening — the open
    /// action then falls back to the GitHub PR page.
    @Published var linearWorkspaceSlug: String {
        didSet { defaults.set(linearWorkspaceSlug, forKey: Keys.linearWorkspaceSlug) }
    }

    /// The postpone duration applied by the `S` quick-snooze verb. Default `.oneDay`
    /// (`SnoozeDuration.quickDefault`). The clock button and row menu still expose
    /// every duration regardless of this setting.
    @Published var defaultSnoozeDuration: SnoozeDuration {
        didSet { defaults.set(defaultSnoozeDuration.rawValue, forKey: Keys.defaultSnoozeDuration) }
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
    /// to this (capped to the display). Default 1600.
    @Published var panelHeight: Int {
        didSet { defaults.set(panelHeight, forKey: Keys.panelHeight) }
    }

    /// Preferred MIN panel content height — the panel never shrinks below this even
    /// with few PRs. Clamped not to exceed `panelHeight` downstream. Default 600.
    @Published var panelMinHeight: Int {
        didSet { defaults.set(panelMinHeight, forKey: Keys.panelMinHeight) }
    }

    /// What the menu-bar badge counts. Default `totalOpen`.
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

    // MARK: - Vercel preview detection

    /// Whether Mainline detects a Vercel preview deployment for each PR (from the
    /// `vercel[bot]` comment) and surfaces the "Preview" indicator + `E` verb.
    /// Default ON. Turning it off stops the extra per-PR comment fetches.
    @Published var vercelPreviewEnabled: Bool {
        didSet { defaults.set(vercelPreviewEnabled, forKey: Keys.vercelPreviewEnabled) }
    }

    /// Ordered list of host suffixes a preview URL must match, most-preferred
    /// first — the extractor returns the first suffix that yields a match (mirrors
    /// the Alfred workflow: custom `dash0-preview.com` before generic `vercel.app`).
    /// Extend this in Settings to support other custom preview domains.
    @Published var vercelPreviewDomains: [String] {
        didSet { defaults.set(vercelPreviewDomains, forKey: Keys.vercelPreviewDomains) }
    }

    /// Default preview host suffixes, in priority order.
    static let defaultVercelPreviewDomains = ["dash0-preview.com", "vercel.app"]

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

    // MARK: - In-app binding glyph helpers

    /// Emits modifier glyphs in the conventional Cocoa order (⇧⌃⌥⌘) for the
    /// flags that are set. Reuses the same ordering as `globalShortcutDisplayString`.
    static func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.shift)   { out += "⇧" }
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option)  { out += "⌥" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    /// Human-readable rendering of an in-app `ShortcutBinding`, e.g. "⌘Z",
    /// "E", "Space", "—". Modifier glyphs precede the key glyph using the
    /// same `⇧⌃⌥⌘` order as the global shortcut display.
    static func glyph(for binding: ShortcutBinding) -> String {
        let mods = modifierGlyphs(binding.modifierFlags)
        if binding.key.isEmpty { return "—" }
        if binding.key == " "  { return mods + "Space" }
        return mods + binding.key.uppercased()
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

    // MARK: - In-app keyboard shortcuts

    /// Per-action key bindings for in-popover keyboard shortcuts. Persisted as
    /// JSON data in UserDefaults. Defaults to `InAppShortcutBindings.defaults`
    /// when no stored value is present.
    @Published var shortcutBindings: InAppShortcutBindings {
        didSet {
            if let data = try? JSONEncoder().encode(shortcutBindings) {
                defaults.set(data, forKey: Keys.shortcutBindings)
            }
        }
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
        // Poll interval — default 30s
        if defaults.object(forKey: Keys.pollIntervalSeconds) == nil {
            defaults.set(30, forKey: Keys.pollIntervalSeconds)
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

        // Quick-snooze duration for the `S` verb — default matches `SnoozeDuration.quickDefault`
        defaultSnoozeDuration = defaults.string(forKey: Keys.defaultSnoozeDuration)
            .flatMap { SnoozeDuration(rawValue: $0) } ?? .quickDefault

        // Collapsed sections — default: Postponed + Done collapsed (low-priority
        // buckets stay folded until the user expands them).
        collapsedSectionsRaw = defaults.stringArray(forKey: Keys.collapsedSectionsRaw)
            ?? [ActionGroup.postponed.rawValue, ActionGroup.done.rawValue]

        // Attention policy — defaults are baked into PREvent.defaults
        attentionPolicy = defaults.dictionary(forKey: Keys.attentionPolicy) as? [String: String] ?? [:]
        unreadPRIdsList = defaults.stringArray(forKey: Keys.unreadPRIds) ?? []
        notifMutedNodeIdsList = defaults.stringArray(forKey: Keys.notifMutedNodeIds) ?? []
        panelHeight     = defaults.object(forKey: Keys.panelHeight) == nil ? 1600 : defaults.integer(forKey: Keys.panelHeight)
        panelMinHeight  = defaults.object(forKey: Keys.panelMinHeight) == nil ? 600 : defaults.integer(forKey: Keys.panelMinHeight)

        // Menu-bar badge — default: count "Total Open", follow selected scope
        menuBarMetric = defaults.string(forKey: Keys.menuBarMetric)
            .flatMap { MenuBarMetric(rawValue: $0) } ?? .totalOpen
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

        // PR open target — default GitHub; Linear also needs a workspace slug
        prOpenTarget = defaults.string(forKey: Keys.prOpenTarget)
            .flatMap { PROpenTarget(rawValue: $0) } ?? .github
        linearWorkspaceSlug = defaults.string(forKey: Keys.linearWorkspaceSlug) ?? ""

        // Vercel preview detection — default ON, with the dash0 + vercel.app suffixes
        vercelPreviewEnabled = defaults.object(forKey: Keys.vercelPreviewEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.vercelPreviewEnabled)
        vercelPreviewDomains = defaults.stringArray(forKey: Keys.vercelPreviewDomains)
            ?? Self.defaultVercelPreviewDomains

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

        // In-app shortcut bindings — decode from JSON data; default factory bindings
        if let data = defaults.data(forKey: Keys.shortcutBindings),
           let decoded = try? JSONDecoder().decode(InAppShortcutBindings.self, from: data) {
            shortcutBindings = decoded
        } else {
            shortcutBindings = .defaults
        }

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

// MARK: - PR open target resolution

extension PRSnapshot {
    /// The URL to open when the user "opens" this PR, honoring `prOpenTarget`.
    /// When Linear is selected but no Linear issue can be derived (no workspace
    /// slug configured, or the branch carries no issue id), transparently falls
    /// back to the GitHub PR page — so the open action always does *something*.
    func openURL(settings: MainlineSettings) -> URL? {
        if settings.prOpenTarget == .linear,
           let linear = PROpenTarget.linearIssueURL(branch: headRefName,
                                                     workspaceSlug: settings.linearWorkspaceSlug) {
            return linear
        }
        return URL(string: htmlUrl)
    }
}
