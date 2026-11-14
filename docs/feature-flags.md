# Feature flags and A/B testing

Mainline ships its flag registry with the code, the same model as LoreKit's `@lorekit/feature-flags`. There is no remote service: **ramping a flag is a release**. Use flags to merge code to production that only the owner sees, then ramp it to a percentage of Macs or split it for an A/B test.

## Resolution order

`FeatureFlagProvider.resolve` returns a value, a variant, and a reason:

1. **Developer override** (`override`): a variant key set in Settings → Developer, validated against the registry. An override naming no variant is ignored.
2. **Enabled experiment** (`split`): the Mac's targeting key is hashed into a bucket and mapped to an arm by cumulative weight.
3. **Default** (`static`): `defaultVariant`. Also used when the experiment is `enabled: false`.

An unknown flag key resolves with reason `error` and no value; the typed accessors then return your fallback.

## Files

| File | Role |
|------|------|
| `Services/FeatureFlags/FeatureFlagSchema.swift` | `FlagDefinition`, `FlagValue`, experiment types, `FeatureFlagRegistry.validate` |
| `Services/FeatureFlags/FeatureFlagRegistry.swift` | The one hand-authored list, `FeatureFlagRegistry.flags` |
| `Services/FeatureFlags/FeatureFlagBucketing.swift` | FNV-1a bucketing, identical to LoreKit |
| `Services/FeatureFlags/FeatureFlagProvider.swift` | Pure resolver: override, split, static |
| `Services/FeatureFlags/FeatureFlagClient.swift` | `FeatureFlagClient.shared`: wires registry, overrides, targeting key, telemetry |
| `Services/FeatureFlags/FeatureFlagAccess.swift` | Owner gating for the Developer pane |
| `Services/FeatureFlags/FeatureFlagChecks.swift` | `#if DEBUG` self-checks (`FeatureFlagChecks.run()`) |
| `Views/DeveloperSettingsView.swift` | Settings → Developer |

## Adding a flag

Add a `FlagDefinition` to `FeatureFlagRegistry.flags`. Only add a flag that gates real code; no placeholders. Keys are kebab-case. Every variant value must match `type`, and `defaultVariant` must be a variant key.

```swift
FlagDefinition(
    key: "new-deck-layout",
    description: "Compact deck rows",
    type: .boolean,
    variants: ["off": .bool(false), "on": .bool(true)],
    defaultVariant: "off",
    owner: "mthines"
)
```

Read it where the code branches:

```swift
if FeatureFlagClient.shared.isEnabled("new-deck-layout") { ... }
```

An invalid registry trips an `assert` in DEBUG builds (and `FeatureFlagChecks`). A release build drops only the invalid definitions.

## Release it dark, visible only to you

Ship with `defaultVariant: "off"` and no experiment. In a release build, Settings → Developer is listed only when `githubUsername` is on the owner allowlist (default `mthines`, case-insensitive, `featureFlagOwnerLogins` in UserDefaults). Pick the `on` variant as an override. Other users resolve `off`. The pane is a UI gate, not a security boundary: an override only changes what this Mac renders.

## Ramp or run an experiment

Add an `experiment` and ship. Arms are `FlagExperimentArm(key:weight:)` and weights must sum to 100.

```swift
experiment: FlagExperiment(enabled: true, arms: [
    FlagExperimentArm(key: "off", weight: 90),
    FlagExperimentArm(key: "on", weight: 10),
])
```

To ramp, raise the `on` weight in a later release (10, 50, 100). A Mac's bucket is stable, so Macs already on `on` stay on it as the weight grows. Setting `enabled: false` returns everyone to `defaultVariant` without deleting the arms.

Bucketing is `FNV-1a-32(utf16("<flagKey>:<targetingKey>")) % 100`, then a walk of cumulative weights. The hash covers UTF-16 code units and uses wrapping multiplication, so it matches LoreKit byte for byte. The targeting key is `TelemetryService.anonymousUserId()`, the same value sent as `enduser.id`, so an arm joins to existing telemetry. It is computed only when an enabled experiment needs it. The key is a hash of the hardware UUID, stable per Mac.

## Telemetry

With usage data on, each evaluation increments `mainline.feature_flag.evaluations` and logs "Feature flag evaluated" once per distinct (flag, variant, reason) per launch. Attributes: `feature_flag.key`, `feature_flag.result.variant`, `feature_flag.result.reason` (`override`, `split`, `static`, `error`), `feature_flag.provider.name` (`mainline-flags`). Nothing is sent when telemetry is off, and no PR, repo, branch, or login data is attached. To compare arms, filter by `feature_flag.result.variant` and join on `enduser.id`.

The Developer pane reads flags without recording, so browsing it does not count as exposure. Filter out `reason = override` when analysing an experiment.

## Removing a flag

Once a flag is at 100% or abandoned, delete the branch in code, then the registry entry, then ship. A stale override in UserDefaults for a removed key is ignored.
