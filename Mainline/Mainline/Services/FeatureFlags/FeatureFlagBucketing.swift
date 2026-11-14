import Foundation

/// Deterministic, stateless variant assignment for A/B(/n) experiments.
///
/// Byte-identical to LoreKit's `bucketing.ts`: FNV-1a (32-bit) over the UTF-16 code
/// units of `"<flagKey>:<targetingKey>"` (what JS `charCodeAt` walks), `% 100`, then a
/// walk of the arms' cumulative weight. The same pair always lands in the same arm.
enum FeatureFlagBucketing {
    /// FNV-1a, 32-bit. Wrapping multiply is load-bearing (`&*`).
    static func fnv1aHash(_ input: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for unit in input.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x01000193
        }
        return hash
    }

    /// Maps a hash into `0..<100`, the same domain as an arm's weight.
    static func bucket(flagKey: String, targetingKey: String) -> Int {
        Int(fnv1aHash("\(flagKey):\(targetingKey)") % 100)
    }

    /// Walks arms in declared order accumulating weight; first arm whose range contains
    /// the bucket wins. Validation guarantees weights sum to 100.
    static func assign(flagKey: String, experiment: FlagExperiment, targetingKey: String) -> String {
        let bucket = Double(bucket(flagKey: flagKey, targetingKey: targetingKey))
        var cumulative = 0.0
        for arm in experiment.arms {
            cumulative += arm.weight
            if bucket < cumulative { return arm.key }
        }
        return experiment.arms[experiment.arms.count - 1].key
    }
}
