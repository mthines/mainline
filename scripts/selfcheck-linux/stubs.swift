// Stand-ins for app types the compiled files reference; only these self-check runs use them.
// IssueChecks (not run here) references the @MainActor IssueStore.
enum IssueStore { static func allIssuesQueries(orgs: [String], repos: [String], users: [String] = []) -> [String] { fatalError("stub") } }
// FeatureFlagClient's app wiring: no overrides, telemetry off.
final class MainlineSettings { static let shared = MainlineSettings(); var featureFlagOverrides: [String: String] = [:] }
final class TelemetryService {
    static let shared = TelemetryService()
    static func anonymousUserId() -> String { "harness" }
    func recordFlagEvaluation(key: String, variant: String?, reason: String, providerName: String) {}
}
