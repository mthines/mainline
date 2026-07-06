import SwiftUI

// MARK: - DiffPreviewView

/// Overlay sheet that shows the unified diff for a PR.
/// Fetched via REST with `Accept: application/vnd.github.v3.diff`.
/// Capped at 512 KB (handled by GitHubClient.fetchDiff).
struct DiffPreviewView: View {
    let pr: PRSnapshot
    let client: GitHubClient
    @Binding var isPresented: Bool

    @State private var diffText: String = ""
    @State private var isLoading: Bool = true
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(.secondary)
                Text("\(pr.repoFullName) #\(pr.number)")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close diff preview")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Text(pr.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)

            Divider()
                .padding(.top, 4)

            // Content
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Fetching diff…")
                        .padding(.vertical, 40)
                    Spacer()
                }
            } else if let error = errorMessage {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Open on GitHub") {
                            if let url = URL(string: pr.htmlUrl) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(diffText.isEmpty ? "(empty diff)" : diffText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 560)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 12)
        .task {
            await fetchDiff()
        }
    }

    private func fetchDiff() async {
        isLoading = true
        errorMessage = nil
        guard let token = await KeychainHelper.loadToken(), !token.isEmpty else {
            isLoading = false
            errorMessage = "No token — open Settings"
            return
        }
        do {
            diffText = try await client.fetchDiff(
                repoFullName: pr.repoFullName,
                number: pr.number,
                token: token
            )
            if diffText.isEmpty {
                errorMessage = "Diff is empty or too large — view on GitHub"
            }
        } catch GitHubAPIError.unauthorized {
            errorMessage = "Token lacks repo read scope — open Settings"
        } catch {
            errorMessage = "Failed to load diff: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
