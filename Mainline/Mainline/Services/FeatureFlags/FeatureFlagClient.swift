import Foundation

/// The façade the rest of the app evaluates flags through. It owns no logic beyond
/// wiring: registry + the developer's overrides + the targeting key into
/// `FeatureFlagProvider.resolve`, then a telemetry record of the outcome.
///
/// ```swift
/// if FeatureFlagClient.shared.isEnabled("new-deck-layout") { ... }
/// ```
final class FeatureFlagClient {
    static let shared = FeatureFlagClient()

    private let registry: [FlagDefinition]
    private let overrides: () -> [String: String]
    private let targetingKey: () -> String?
    private let record: (FlagResolution) -> Void

    /// Defaults wire the real app: the shipped registry, `MainlineSettings`' overrides, the
    /// same anonymous id telemetry sends as `enduser.id` (so an arm joins to existing
    /// telemetry), and `TelemetryService` (a no-op while telemetry is off).
    ///
    /// The targeting key is computed lazily, only when an enabled experiment actually
    /// needs it, so a registry with no live experiment never touches the device id.
    init(
        registry: [FlagDefinition] = FeatureFlagClient.validRegistry(FeatureFlagRegistry.flags),
        overrides: @escaping () -> [String: String] = { MainlineSettings.shared.featureFlagOverrides },
        targetingKey: @escaping () -> String? = { TelemetryService.anonymousUserId() },
        record: @escaping (FlagResolution) -> Void = FeatureFlagClient.recordToTelemetry
    ) {
        self.registry = registry
        self.overrides = overrides
        self.targetingKey = targetingKey
        self.record = record
    }

    /// An invalid registry is a programming error: DEBUG asserts loudly (and
    /// `FeatureFlagChecks` validates the shipped registry on every dev launch); a release
    /// build keeps only the definitions that pass, so one bad entry cannot crash the app.
    static func validRegistry(_ defs: [FlagDefinition]) -> [FlagDefinition] {
        let errors = FeatureFlagRegistry.validate(defs)
        assert(errors.isEmpty, "Invalid feature-flag registry: \(errors.joined(separator: "; "))")
        if errors.isEmpty { return defs }
        return defs.filter { FeatureFlagRegistry.validate([$0]).isEmpty }
    }

    static func recordToTelemetry(_ resolution: FlagResolution) {
        TelemetryService.shared.recordFlagEvaluation(
            key: resolution.flagKey,
            variant: resolution.variant,
            reason: resolution.reason.rawValue,
            providerName: FeatureFlagProvider.providerName
        )
    }

    /// Every flag in the registry, for the Developer pane.
    var definitions: [FlagDefinition] { registry }

    /// Resolves a flag and records the evaluation.
    func evaluate(_ key: String) -> FlagResolution {
        let resolution = resolveWithoutRecording(key)
        record(resolution)
        return resolution
    }

    /// Resolves without a telemetry record — for the Developer pane, which lists flags
    /// rather than exposing a user to them.
    func resolveWithoutRecording(_ key: String) -> FlagResolution {
        FeatureFlagProvider.resolve(key, registry: registry, overrides: overrides(), targetingKey: targetingKey)
    }

    func boolValue(_ key: String, default fallback: Bool = false) -> Bool {
        if case .bool(let value)? = evaluate(key).value { return value }
        return fallback
    }

    func isEnabled(_ key: String) -> Bool { boolValue(key) }

    func stringValue(_ key: String, default fallback: String) -> String {
        if case .string(let value)? = evaluate(key).value { return value }
        return fallback
    }

    func numberValue(_ key: String, default fallback: Double) -> Double {
        if case .number(let value)? = evaluate(key).value { return value }
        return fallback
    }
}
