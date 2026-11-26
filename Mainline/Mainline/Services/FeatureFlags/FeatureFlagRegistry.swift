import Foundation

/// The single hand-authored source of truth for Mainline's feature flags.
///
/// Add a flag only when it gates real code — never a placeholder. A flag with an
/// `experiment` ramps by percentage / A/B-splits; ramping is a release (edit the
/// weights, ship). See `docs/feature-flags.md`.
///
/// ```swift
/// FlagDefinition(
///     key: "new-deck-layout",
///     description: "Compact deck rows",
///     type: .boolean,
///     variants: ["off": .bool(false), "on": .bool(true)],
///     defaultVariant: "off",
///     experiment: FlagExperiment(enabled: true, arms: [
///         FlagExperimentArm(key: "off", weight: 90),
///         FlagExperimentArm(key: "on", weight: 10),
///     ]),
///     owner: "mthines",
///     tags: ["deck"]
/// )
/// ```
enum FeatureFlagRegistry {
    static let flags: [FlagDefinition] = [
        FlagDefinition(
            key: issuePromptsKey,
            description: "Run prompt templates on issues (A key, row and section menus on the Issues tab)",
            type: .boolean,
            variants: ["off": .bool(false), "on": .bool(true)],
            defaultVariant: "on",
            experiment: nil,
            owner: "mthines",
            tags: ["issues", "prompts"]
        ),
        FlagDefinition(
            key: issueHooksKey,
            description: "Hooks on issues: a template with `on:` and `for: issues` starts by itself on issue changes",
            type: .boolean,
            variants: ["off": .bool(false), "on": .bool(true)],
            defaultVariant: "off",
            experiment: nil,
            owner: "mthines",
            tags: ["issues", "hooks"]
        ),
        FlagDefinition(
            key: checkHooksKey,
            description: "Hooks on one named CI check: `on: check-failed` / `check-passed` with `check:` start by themselves when that check changes",
            type: .boolean,
            variants: ["off": .bool(false), "on": .bool(true)],
            defaultVariant: "off",
            experiment: nil,
            owner: "mthines",
            tags: ["hooks", "ci"]
        ),
        FlagDefinition(
            key: hookEditorKey,
            description: "Edit hooks in Settings → Prompts: a sheet for triggers, PR scope, repos and the prompt, plus an on/off switch per hook",
            type: .boolean,
            variants: ["off": .bool(false), "on": .bool(true)],
            defaultVariant: "off",
            experiment: nil,
            owner: "mthines",
            tags: ["hooks", "settings"]
        ),
    ]

    /// Gates running prompt templates on issues.
    static let issuePromptsKey = "issue-prompts"

    /// Resolved without a telemetry record: it is read while rendering the Issues tab and
    /// its key legend, which would otherwise count an evaluation per redraw.
    static var issuePromptsEnabled: Bool {
        if case .bool(true)? = FeatureFlagClient.shared.resolveWithoutRecording(issuePromptsKey).value { return true }
        return false
    }

    /// Gates hooks on issues (issue triggers, their events, Settings and starter text).
    static let issueHooksKey = "issue-hooks"

    /// Resolved without a telemetry record: Settings reads it on every render and the issue
    /// poll on every cycle.
    static var issueHooksEnabled: Bool {
        if case .bool(true)? = FeatureFlagClient.shared.resolveWithoutRecording(issueHooksKey).value { return true }
        return false
    }

    /// Gates hooks on one named CI check (check triggers, the per-check query selection, Settings and starter text).
    static let checkHooksKey = "check-hooks"

    /// Resolved without a telemetry record: Settings reads it on every render and every poll asks it
    /// whether to request per-check data.
    static var checkHooksEnabled: Bool {
        if case .bool(true)? = FeatureFlagClient.shared.resolveWithoutRecording(checkHooksKey).value { return true }
        return false
    }

    /// Gates the Settings hook editor sheet (`hooks` list rows, switch, New Hook). Off = today's Hooks section.
    static let hookEditorKey = "hook-editor"

    /// Resolved without a telemetry record: Settings reads it on every render.
    static var hookEditorEnabled: Bool {
        if case .bool(true)? = FeatureFlagClient.shared.resolveWithoutRecording(hookEditorKey).value { return true }
        return false
    }
}
