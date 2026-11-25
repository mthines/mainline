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
    ]

    /// Gates running prompt templates on issues.
    static let issuePromptsKey = "issue-prompts"

    /// Resolved without a telemetry record: it is read while rendering the Issues tab and
    /// its key legend, which would otherwise count an evaluation per redraw.
    static var issuePromptsEnabled: Bool {
        if case .bool(true)? = FeatureFlagClient.shared.resolveWithoutRecording(issuePromptsKey).value { return true }
        return false
    }
}
