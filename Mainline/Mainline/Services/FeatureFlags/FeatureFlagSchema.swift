import Foundation

// MARK: - FlagValue

/// The JSON-like value space a flag variant can carry. Mirrors OpenFeature's four
/// evaluation types (boolean / string / number / object).
enum FlagValue: Equatable {
    case bool(Bool)
    case string(String)
    case number(Double)
    case object([String: FlagValue])

    var type: FlagType {
        switch self {
        case .bool:   return .boolean
        case .string: return .string
        case .number: return .number
        case .object: return .object
        }
    }
}

enum FlagType: String {
    case boolean, string, number, object
}

// MARK: - Definitions

/// One arm of an experiment. `weight` values across all arms must sum to 100.
struct FlagExperimentArm: Equatable {
    let key: String
    let weight: Double
}

/// A/B(/n) rollout config. `enabled == false` keeps the arms declared (so the
/// experiment can be re-launched) while every evaluation resolves to `defaultVariant`.
struct FlagExperiment: Equatable {
    var enabled: Bool
    var arms: [FlagExperimentArm]
}

/// A flag definition. Data, not code: the registry is the single source of truth and
/// `FeatureFlagRegistry.validate(_:)` rejects a malformed one.
struct FlagDefinition: Equatable {
    let key: String
    let description: String
    let type: FlagType
    /// Variant key → the value returned for that variant. Must contain `defaultVariant`.
    let variants: [String: FlagValue]
    let defaultVariant: String
    let experiment: FlagExperiment?
    /// Who owns the flag — surfaced for cleanup audits.
    let owner: String
    let tags: [String]

    init(
        key: String,
        description: String,
        type: FlagType,
        variants: [String: FlagValue],
        defaultVariant: String,
        experiment: FlagExperiment? = nil,
        owner: String,
        tags: [String] = []
    ) {
        self.key = key
        self.description = description
        self.type = type
        self.variants = variants
        self.defaultVariant = defaultVariant
        self.experiment = experiment
        self.owner = owner
        self.tags = tags
    }

    /// Variant keys in a stable, human-friendly order: default first, then alphabetical.
    var orderedVariantKeys: [String] {
        let rest = variants.keys.filter { $0 != defaultVariant }.sorted()
        return [defaultVariant] + rest
    }
}

// MARK: - Validation

extension FeatureFlagRegistry {
    /// Kebab-case so a key is a legal identifier everywhere: `^[a-z][a-z0-9-]*$`.
    static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first.value >= 97, first.value <= 122 else { return false }
        for scalar in key.unicodeScalars {
            let v = scalar.value
            let isLower = v >= 97 && v <= 122
            let isDigit = v >= 48 && v <= 57
            if !(isLower || isDigit || v == 45) { return false }
        }
        return true
    }

    /// Returns every problem found; an empty array means the registry is valid.
    static func validate(_ defs: [FlagDefinition]) -> [String] {
        var errors: [String] = []

        var seen = Set<String>()
        var dupes = Set<String>()
        for def in defs where !seen.insert(def.key).inserted { dupes.insert(def.key) }
        if !dupes.isEmpty {
            errors.append("duplicate flag keys: \(dupes.sorted().joined(separator: ", "))")
        }

        for def in defs {
            if !isValidKey(def.key) {
                errors.append("flag key \"\(def.key)\" must be kebab-case")
            }
            if def.description.isEmpty { errors.append("\(def.key): description is empty") }
            if def.owner.isEmpty { errors.append("\(def.key): owner is empty") }
            if def.variants[def.defaultVariant] == nil {
                errors.append("\(def.key): defaultVariant \"\(def.defaultVariant)\" is not a key of variants")
            }
            if def.variants.values.contains(where: { $0.type != def.type }) {
                errors.append("\(def.key): all variant values must be of declared type \"\(def.type.rawValue)\"")
            }
            if let experiment = def.experiment {
                if experiment.arms.count < 2 {
                    errors.append("\(def.key): experiment needs at least 2 variants")
                }
                let total = experiment.arms.reduce(0.0) { $0 + $1.weight }
                if abs(total - 100) > 0.001 {
                    errors.append("\(def.key): experiment weights must sum to 100, got \(total)")
                }
                if experiment.arms.contains(where: { $0.weight < 0 || $0.weight > 100 }) {
                    errors.append("\(def.key): experiment weights must be within 0...100")
                }
                let armKeys = experiment.arms.map(\.key)
                if Set(armKeys).count != armKeys.count {
                    errors.append("\(def.key): experiment variant keys must be unique")
                }
                for arm in experiment.arms where def.variants[arm.key] == nil {
                    errors.append("\(def.key): experiment variant \"\(arm.key)\" is not a key of variants")
                }
            }
        }
        return errors
    }
}
