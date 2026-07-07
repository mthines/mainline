import Foundation

// MARK: - SensitivePathMatcher

/// Pure client-side heuristic classifier for sensitive file paths.
/// No I/O — all matching is done against string patterns.
/// Mirrors the `PRDiffEngine` pure enum pattern.
enum SensitivePathMatcher {

    // MARK: - Pattern constants

    /// Exact filenames that are always sensitive.
    static let sensitiveFilenames: Set<String> = [
        "Package.resolved",
        "Podfile.lock",
        "Gemfile.lock",
        "yarn.lock",
        "package-lock.json",
        "pnpm-lock.yaml",
        "Cargo.lock",
        "go.sum",
        ".env",
        ".env.local",
        ".env.production",
        ".env.staging",
    ]

    /// Path prefixes or substrings that flag a path as sensitive.
    static let sensitivePrefixPatterns: [String] = [
        "migrations/",
        "db/migrate",
        "database/migrations",
        ".github/workflows/",
        ".github/actions/",
        "ci/",
        ".circleci/",
        ".buildkite/",
        "infra/",
        "terraform/",
        "helm/",
        "k8s/",
        "kubernetes/",
        "auth/",
        "security/",
        "secrets/",
        "certs/",
    ]

    /// File suffixes that are sensitive regardless of directory.
    static let sensitiveSuffixes: [String] = [
        ".pem",
        ".key",
        ".crt",
        ".cer",
        ".p12",
        ".pfx",
        ".asc",
        ".tf",            // Terraform
        ".tfvars",        // Terraform variables
    ]

    // MARK: - Public API

    /// Returns true if the given path (filename or full path component) is
    /// considered sensitive by any of the heuristic patterns.
    static func isSensitive(_ path: String) -> Bool {
        let lower = path.lowercased()
        let filename = (path as NSString).lastPathComponent

        // Exact filename match
        if sensitiveFilenames.contains(filename) { return true }

        // Suffix match
        for suffix in sensitiveSuffixes {
            if lower.hasSuffix(suffix) { return true }
        }

        // Prefix/substring match
        for pattern in sensitivePrefixPatterns {
            if lower.contains(pattern) { return true }
        }

        return false
    }

    /// Returns true if any path in the collection is sensitive.
    static func containsSensitive(_ paths: [String]) -> Bool {
        paths.contains { isSensitive($0) }
    }
}
