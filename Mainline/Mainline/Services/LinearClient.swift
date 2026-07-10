import Foundation

/// Minimal Linear GraphQL client — resolves the Linear issue linked to a GitHub
/// PR via Linear's attachment index (`attachmentsForURL`).
///
/// Linear's GitHub integration records each linked PR as an *attachment* on the
/// issue, keyed by the PR's html URL. That link is the only reliable association
/// when the branch name carries no `TEAM-123` identifier (e.g. AI-agent branches
/// like `codex/…` or `claude/…`). We look it up on demand — only when the user
/// actually opens a PR and `prOpenTarget == .linear` — so there is no polling cost.
///
/// Auth: a Linear *personal API key* (starts with `lin_api_`) passed verbatim in
/// the `Authorization` header (Linear does NOT use a `Bearer` prefix for these).
enum LinearClient {
    private static let endpoint = URL(string: "https://api.linear.app/graphql")!

    /// Returns the Linear issue URL linked to `prURL` (as an attachment), or nil
    /// when there is no linked issue, no key, or the request fails. Never throws —
    /// callers treat nil as "fall back to GitHub".
    static func issueURL(forPRURL prURL: String, apiKey: String) async -> URL? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !prURL.isEmpty else { return nil }

        let query = "query($url: String!) { attachmentsForURL(url: $url) { nodes { issue { url } } } }"
        let payload: [String: Any] = ["query": query, "variables": ["url": prURL]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let dataObj = json["data"] as? [String: Any],
                let attachments = dataObj["attachmentsForURL"] as? [String: Any],
                let nodes = attachments["nodes"] as? [[String: Any]]
            else { return nil }

            for node in nodes {
                if let issue = node["issue"] as? [String: Any],
                   let urlString = issue["url"] as? String,
                   let url = URL(string: urlString) {
                    return url
                }
            }
            return nil
        } catch {
            return nil
        }
    }
}
