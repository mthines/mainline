import Foundation

// MARK: - AttentionLevel

/// The interruption level for a PR event.
enum AttentionLevel: String, Codable, CaseIterable {
    case notify  // banner + sound + badge update + adds to unread
    case quiet   // badge/unread update only — no banner, no sound
    case off     // no action at all
}

// MARK: - PREvent

/// All PR event types that can generate attention.
enum PREvent: String, Codable, CaseIterable {
    case newPRByMe           // new PR opened by me (authored)
    case reviewRequested     // DIRECT review requested from me (my login)
    case reviewRequestedTeam // review requested from a team I belong to
    case ciFailedOnMyPR      // CI failed on my PR
    case changesRequested    // reviewer requested changes on my PR
    case newReviewOrComment  // new review or comment needing response
    case readyForReview      // PR transitioned from draft to ready
    case prMerged            // PR was merged
    case prClosed            // PR was closed (not merged)
    case ciPassedOnMyPR      // CI turned green on my PR
    case draftCreated        // new draft PR created

    /// Whether this event can actually be produced by
    /// `NotificationService.resolveTransition`.
    ///
    /// `PRTransition` has only four cases, so three events have never been
    /// emitted by any code path: setting an attention level for them did nothing,
    /// which is a large part of why the Attention Policy pane felt broken. The
    /// cases are deliberately KEPT rather than deleted — persisted policy
    /// dictionaries on disk may still carry their `rawValue` keys, and they
    /// document transitions the diff engine may gain later.
    ///
    /// This is the single source of truth the Settings UI renders from, so the
    /// pane and the notification service cannot drift again. The switch is
    /// exhaustive on purpose (no `default:`) so adding a `PREvent` is a compile
    /// error until its deliverability is declared.
    var isDeliverable: Bool {
        switch self {
        case .newPRByMe,
             .reviewRequested,
             .reviewRequestedTeam,
             .ciFailedOnMyPR,
             .ciPassedOnMyPR,
             .newReviewOrComment,
             .readyForReview,
             .draftCreated:
            return true
        case .changesRequested,
             .prMerged,
             .prClosed:
            return false
        }
    }

    /// Every event the notification service can actually deliver, in `allCases`
    /// order. `SettingsView.notificationsSection` iterates this instead of
    /// `allCases` so it never renders a row that cannot fire.
    static let deliverable: [PREvent] = PREvent.allCases.filter { $0.isDeliverable }

    /// Human-readable label for Settings UI.
    var displayName: String {
        switch self {
        case .newPRByMe:          return "New PR opened by me"
        case .reviewRequested:    return "Review requested from me"
        case .reviewRequestedTeam: return "Team review requested"
        case .ciFailedOnMyPR:     return "CI failed on my PR"
        case .changesRequested:   return "Changes requested on my PR"
        case .newReviewOrComment: return "New review or comment"
        case .readyForReview:     return "PR ready for review"
        case .prMerged:           return "PR merged"
        case .prClosed:           return "PR closed"
        case .ciPassedOnMyPR:     return "CI passed on my PR"
        case .draftCreated:       return "Draft PR created"
        }
    }
}

// MARK: - Default attention policy (attention-respectful defaults)

extension PREvent {
    /// The default attention level — baked in to be attention-respectful.
    static let defaults: [PREvent: AttentionLevel] = [
        .newPRByMe:          .notify,
        // DIRECT request — banners. `resolveTransition` routes EVERY new PR you
        // did not author here, so a `.quiet` default made "New PR" banners
        // unreachable for anyone but yourself. It was also incoherent with
        // `.readyForReview` (`.notify`), which the diff engine emits when a review
        // is requested on an ALREADY-tracked PR: known PRs rang, brand-new ones
        // were silent. Existing users are upgraded once by `migratedPolicy(from:)`.
        .reviewRequested:    .notify,
        .reviewRequestedTeam: .quiet,   // team pulled it in — legitimately lower signal
        .ciFailedOnMyPR:     .notify,
        .changesRequested:   .notify,
        .newReviewOrComment: .notify,
        .readyForReview:     .notify,
        .prMerged:           .quiet,   // good news / terminal — no focus steal
        .prClosed:           .quiet,   // terminal state
        .ciPassedOnMyPR:     .quiet,   // good news — silent update
        .draftCreated:       .quiet,   // not actionable yet
    ]
}

// MARK: - Persisted-policy migration

extension PREvent {
    /// Current version of the persisted `attentionPolicy` dictionary shape.
    ///
    /// Bump this (and extend `migratedPolicy(from:)`) whenever a change to
    /// `defaults` needs to reach users who already have a value on disk.
    /// `MainlineSettings` stores the last-applied version under
    /// `Keys.attentionPolicyMigrationVersion` and runs the upgrade exactly once.
    ///
    /// - v1: `reviewRequested` default flipped `.quiet` → `.notify`.
    static let policyMigrationVersion = 1

    /// Pure. Upgrades a persisted `[PREvent.rawValue: AttentionLevel.rawValue]`
    /// dictionary to the current policy version.
    ///
    /// Why this is needed at all: `MainlineSettings.level(for:)` falls back to
    /// `defaults` only when the key is ABSENT. Anyone who has ever opened the
    /// Notifications pane has every visible event written to disk — including
    /// `reviewRequested: "quiet"`, the OLD default — so flipping `defaults`
    /// alone would never reach them and the bug would persist.
    ///
    /// v1 removes a stored `reviewRequested: "quiet"` rather than writing
    /// `"notify"`. Removal restores "absent means follow the baked-in default",
    /// so a future default change also reaches these users; writing a literal
    /// would re-pin them forever. A stored `"off"` is left untouched — that is
    /// unambiguously a deliberate choice to silence the event, and only the old
    /// default value is ambiguous enough to migrate. Every other event's stored
    /// value is passed through unchanged.
    static func migratedPolicy(from stored: [String: String]) -> [String: String] {
        var next = stored

        // v1 — reviewRequested: quiet (the old default) → follow the new default.
        if next[PREvent.reviewRequested.rawValue] == AttentionLevel.quiet.rawValue {
            next.removeValue(forKey: PREvent.reviewRequested.rawValue)
        }

        return next
    }
}

// MARK: - Attention policy self-checks (DEBUG)

#if DEBUG
/// Lightweight, dependency-free assertions for the pure attention-policy logic:
/// the delivery defaults, the persisted-policy migration table, and the
/// deliverable-event set. Mirrors `InboxMuteEngine.runSelfChecks()` and
/// `PRClassificationChecks.run()` — invoked once at launch so a regression trips
/// an assertion in a debug build without a full XCTest target.
enum AttentionPolicyChecks {
    static func run() {
        // MARK: Defaults — a new PR from someone else must be able to ring.
        assert(PREvent.defaults[.reviewRequested] == .notify,
               "reviewRequested must default to notify — every new PR you didn't author routes here")
        assert(PREvent.defaults[.reviewRequestedTeam] == .quiet,
               "team review requests stay quiet (lower signal)")
        // Every event the service can deliver needs a default to fall back on.
        for event in PREvent.deliverable {
            assert(PREvent.defaults[event] != nil,
                   "deliverable event \(event.rawValue) has no default attention level")
        }

        // MARK: Migration — the old default is upgraded, deliberate choices survive.
        let rr = PREvent.reviewRequested.rawValue

        // A stored old default is removed, so `level(for:)` falls through to .notify.
        assert(PREvent.migratedPolicy(from: [rr: "quiet"])[rr] == nil,
               "migration must clear a stored reviewRequested:quiet")
        // A deliberate silence is preserved.
        assert(PREvent.migratedPolicy(from: [rr: "off"])[rr] == "off",
               "migration must preserve a deliberate reviewRequested:off")
        // An explicit notify is already correct and stays put.
        assert(PREvent.migratedPolicy(from: [rr: "notify"])[rr] == "notify",
               "migration must preserve an explicit reviewRequested:notify")
        // Other events are untouched, including ones whose default IS quiet.
        let other = PREvent.ciPassedOnMyPR.rawValue
        let mixed = PREvent.migratedPolicy(from: [rr: "quiet", other: "quiet"])
        assert(mixed[other] == "quiet", "migration must not touch other events")
        assert(mixed[rr] == nil, "migration must still clear reviewRequested in a mixed dict")
        // Empty in, empty out — a fresh install migrates to a no-op.
        assert(PREvent.migratedPolicy(from: [:]).isEmpty,
               "migration of an empty policy must stay empty")
        // Idempotent: re-running over its own output changes nothing.
        let once = PREvent.migratedPolicy(from: [rr: "quiet", other: "off"])
        assert(PREvent.migratedPolicy(from: once) == once, "migration must be idempotent")

        // MARK: Deliverable set — dead rows must not reach the Settings pane.
        assert(!PREvent.changesRequested.isDeliverable, "changesRequested is never emitted")
        assert(!PREvent.prMerged.isDeliverable, "prMerged is never emitted")
        assert(!PREvent.prClosed.isDeliverable, "prClosed is never emitted")
        assert(PREvent.reviewRequested.isDeliverable, "reviewRequested IS emitted")
        // `.draftCreated` is emitted by the .readyForReview branch when isDraft.
        assert(PREvent.draftCreated.isDeliverable, "draftCreated IS emitted")
        assert(PREvent.deliverable.count == PREvent.allCases.count - 3,
               "exactly three PREvents are undeliverable")
        assert(!PREvent.deliverable.contains(.prMerged),
               "deliverable list must exclude undeliverable events")
    }
}
#endif
