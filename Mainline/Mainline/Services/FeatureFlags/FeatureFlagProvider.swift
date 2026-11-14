import Foundation

/// Why a flag resolved the way it did. Raw values are the `feature_flag.result.reason`
/// telemetry vocabulary (OpenFeature's reasons lowercased, plus `override`).
enum FlagReason: String {
    case override
    case split
    case `static`
    case error
}

/// The outcome of one evaluation.
struct FlagResolution: Equatable {
    let flagKey: String
    /// `nil` only when `reason == .error` (unknown flag).
    let value: FlagValue?
    let variant: String?
    let reason: FlagReason
    let errorMessage: String?
}

/// Resolves a flag against a registry. Pure: no I/O, no globals.
///
/// Order: developer override (a variant key, validated against the registry) →
/// enabled experiment split → `defaultVariant`. The registry ships with the code, so
/// there is no remote service; ramping is a release.
enum FeatureFlagProvider {
    static let providerName = "mainline-flags"

    /// Used only when an active experiment is evaluated with no targeting key at all:
    /// everyone then gets the same arm, which is not a split.
    static let anonymousTargetingKey = "anonymous"

    /// `targetingKey` is a closure so it is only computed when an experiment needs it.
    static func resolve(
        _ flagKey: String,
        registry: [FlagDefinition],
        overrides: [String: String],
        targetingKey: () -> String?
    ) -> FlagResolution {
        guard let def = registry.first(where: { $0.key == flagKey }) else {
            return FlagResolution(
                flagKey: flagKey, value: nil, variant: nil, reason: .error,
                errorMessage: "flag \"\(flagKey)\" is not in the registry"
            )
        }

        if let overrideVariant = overrides[flagKey], let value = def.variants[overrideVariant] {
            return FlagResolution(
                flagKey: flagKey, value: value, variant: overrideVariant, reason: .override, errorMessage: nil
            )
        }

        var variant = def.defaultVariant
        var reason = FlagReason.static
        if let experiment = def.experiment, experiment.enabled {
            let key = targetingKey().flatMap { $0.isEmpty ? nil : $0 } ?? anonymousTargetingKey
            variant = FeatureFlagBucketing.assign(flagKey: def.key, experiment: experiment, targetingKey: key)
            reason = .split
        }
        return FlagResolution(
            flagKey: flagKey, value: def.variants[variant], variant: variant, reason: reason, errorMessage: nil
        )
    }
}
