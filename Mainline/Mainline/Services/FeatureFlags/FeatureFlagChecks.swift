import Foundation

#if DEBUG
/// `#if DEBUG` self-checks for the flag system (the repo has no XCTest target).
/// Run from `AppDelegate.applicationDidFinishLaunching`. Uses its own fixtures —
/// the shipped registry is validated separately at the end.
enum FeatureFlagChecks {
    private static func boolFlag(
        _ key: String = "example-flag",
        defaultVariant: String = "off",
        experiment: FlagExperiment? = nil
    ) -> FlagDefinition {
        FlagDefinition(
            key: key, description: "d", type: .boolean,
            variants: ["off": .bool(false), "on": .bool(true)],
            defaultVariant: defaultVariant, experiment: experiment, owner: "o"
        )
    }

    private static func split(_ off: Double, _ on: Double, enabled: Bool = true) -> FlagExperiment {
        FlagExperiment(enabled: enabled, arms: [
            FlagExperimentArm(key: "off", weight: off),
            FlagExperimentArm(key: "on", weight: on),
        ])
    }

    static func run() {
        checkHash()
        checkValidation()
        checkResolution()
        checkAccess()
        let shipped = FeatureFlagRegistry.validate(FeatureFlagRegistry.flags)
        assert(shipped.isEmpty, "shipped flag registry must validate: \(shipped)")
    }

    // MARK: hashing (LoreKit-computed vectors)

    private static func checkHash() {
        assert(FeatureFlagBucketing.fnv1aHash("") == 2166136261, "fnv1a of empty string")
        assert(FeatureFlagBucketing.fnv1aHash("a") == 3826002220, "fnv1a of a")
        assert(FeatureFlagBucketing.fnv1aHash("insights-visual:user-123") == 2573777393, "fnv1a vector 3")
        assert(FeatureFlagBucketing.bucket(flagKey: "insights-visual", targetingKey: "user-123") == 93, "bucket 93")
        assert(
            FeatureFlagBucketing.fnv1aHash("example-flag:00000000-0000-0000-0000-000000000000") == 4034025352,
            "fnv1a vector 4"
        )
        assert(
            FeatureFlagBucketing.bucket(flagKey: "example-flag", targetingKey: "00000000-0000-0000-0000-000000000000") == 52,
            "bucket 52"
        )
        assert(FeatureFlagBucketing.fnv1aHash("x:ü") == 1275141281, "fnv1a hashes UTF-16 code units")

        // Bucket 52 against a 50/50 split lands in the second arm; 93 vs 95/5 in the second.
        let exp = split(50, 50)
        assert(FeatureFlagBucketing.assign(flagKey: "example-flag", experiment: exp,
                                           targetingKey: "00000000-0000-0000-0000-000000000000") == "on",
               "bucket 52 → second arm of 50/50")
        assert(FeatureFlagBucketing.assign(flagKey: "example-flag", experiment: split(100, 0),
                                           targetingKey: "anything") == "off",
               "100/0 always first arm")
    }

    // MARK: registry validation

    private static func checkValidation() {
        assert(FeatureFlagRegistry.validate([boolFlag()]).isEmpty, "a good flag validates")
        assert(FeatureFlagRegistry.validate([boolFlag(experiment: split(90, 10))]).isEmpty, "a good experiment validates")

        assert(!FeatureFlagRegistry.validate([boolFlag("Bad_Key")]).isEmpty, "non-kebab key rejected")
        assert(!FeatureFlagRegistry.validate([boolFlag("1abc")]).isEmpty, "key starting with a digit rejected")
        assert(!FeatureFlagRegistry.validate([boolFlag(defaultVariant: "missing")]).isEmpty, "missing defaultVariant rejected")
        assert(!FeatureFlagRegistry.validate([boolFlag(experiment: split(60, 30))]).isEmpty, "weights ≠ 100 rejected")
        assert(!FeatureFlagRegistry.validate([boolFlag(), boolFlag()]).isEmpty, "duplicate keys rejected")

        let wrongType = FlagDefinition(
            key: "typed", description: "d", type: .boolean,
            variants: ["off": .bool(false), "on": .string("yes")], defaultVariant: "off", owner: "o"
        )
        assert(!FeatureFlagRegistry.validate([wrongType]).isEmpty, "wrong value type rejected")

        let unknownArm = FlagExperiment(enabled: true, arms: [
            FlagExperimentArm(key: "off", weight: 50), FlagExperimentArm(key: "ghost", weight: 50),
        ])
        assert(!FeatureFlagRegistry.validate([boolFlag(experiment: unknownArm)]).isEmpty, "arm not in variants rejected")
        let dupArms = FlagExperiment(enabled: true, arms: [
            FlagExperimentArm(key: "off", weight: 50), FlagExperimentArm(key: "off", weight: 50),
        ])
        assert(!FeatureFlagRegistry.validate([boolFlag(experiment: dupArms)]).isEmpty, "duplicate arm keys rejected")
    }

    // MARK: resolution order: override > split > static

    private static func checkResolution() {
        let flag = boolFlag(experiment: split(0, 100))
        let registry = [flag]

        let staticOnly = FeatureFlagProvider.resolve(
            "example-flag", registry: [boolFlag()], overrides: [:], targetingKey: { "u" })
        assert(staticOnly.reason == .static && staticOnly.variant == "off" && staticOnly.value == FlagValue.bool(false),
               "no experiment → static default")

        let disabled = FeatureFlagProvider.resolve(
            "example-flag", registry: [boolFlag(experiment: split(0, 100, enabled: false))],
            overrides: [:], targetingKey: { "u" })
        assert(disabled.reason == .static && disabled.variant == "off", "disabled experiment → default, static")

        let splitRes = FeatureFlagProvider.resolve("example-flag", registry: registry, overrides: [:], targetingKey: { "u" })
        assert(splitRes.reason == .split && splitRes.variant == "on" && splitRes.value == FlagValue.bool(true),
               "enabled experiment → split")

        let overridden = FeatureFlagProvider.resolve(
            "example-flag", registry: registry, overrides: ["example-flag": "off"], targetingKey: { "u" })
        assert(overridden.reason == .override && overridden.variant == "off", "override beats split")

        let badOverride = FeatureFlagProvider.resolve(
            "example-flag", registry: registry, overrides: ["example-flag": "nope"], targetingKey: { "u" })
        assert(badOverride.reason == .split, "an override naming no variant is ignored")

        var asked = false
        _ = FeatureFlagProvider.resolve(
            "example-flag", registry: registry, overrides: ["example-flag": "on"],
            targetingKey: { asked = true; return "u" })
        assert(!asked, "targeting key is not computed when an override decides")

        let unknown = FeatureFlagProvider.resolve("nope", registry: registry, overrides: [:], targetingKey: { "u" })
        assert(unknown.reason == .error && unknown.value == nil, "unknown flag → error")

        // Client wiring: typed accessors, records every evaluation, not the listing path.
        var recorded: [FlagResolution] = []
        let client = FeatureFlagClient(
            registry: registry, overrides: { [:] }, targetingKey: { "u" }, record: { recorded.append($0) })
        assert(client.isEnabled("example-flag"), "client resolves the split arm")
        assert(!client.isEnabled("nope"), "unknown flag falls back to the default")
        assert(recorded.count == 2 && recorded[1].reason == .error, "every evaluation is recorded")
        _ = client.resolveWithoutRecording("example-flag")
        assert(recorded.count == 2, "listing does not record")

        // Distribution sanity: a 50/50 split over many keys is roughly even.
        let exp = split(50, 50)
        var on = 0
        for i in 0..<2000
        where FeatureFlagBucketing.assign(flagKey: "dist", experiment: exp, targetingKey: "user-\(i)") == "on" { on += 1 }
        assert(on > 800 && on < 1200, "50/50 split is roughly even (got \(on)/2000)")
    }

    // MARK: owner gating

    private static func checkAccess() {
        assert(FeatureFlagAccess.isOwner(login: "MThines", allowlist: ["mthines"]), "owner match is case-insensitive")
        assert(!FeatureFlagAccess.isOwner(login: "someone", allowlist: ["mthines"]), "non-owner rejected")
        assert(!FeatureFlagAccess.isOwner(login: "", allowlist: ["mthines"]), "empty login never matches")
        assert(FeatureFlagAccess.defaultOwnerLogins == ["mthines"], "default owner allowlist")
        assert(!FeatureFlagAccess.developerPaneVisible(login: "someone", allowlist: ["mthines"], isDebugBuild: false),
               "release + non-owner → hidden")
        assert(FeatureFlagAccess.developerPaneVisible(login: "mthines", allowlist: ["mthines"], isDebugBuild: false),
               "release + owner → visible")
        assert(FeatureFlagAccess.developerPaneVisible(login: "", allowlist: [], isDebugBuild: true),
               "debug build → visible")
    }
}
#endif
