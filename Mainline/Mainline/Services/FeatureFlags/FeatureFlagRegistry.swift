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
    static let flags: [FlagDefinition] = []
}
