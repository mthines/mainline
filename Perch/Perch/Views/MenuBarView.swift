import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var manager: PRManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // PR list
            if manager.prs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        prSection(
                            title: "My PRs",
                            prs: manager.prs.filter { $0.author == manager.settings.githubUsername }
                        )
                        prSection(
                            title: "Review Requested",
                            prs: manager.prs.filter {
                                $0.author != manager.settings.githubUsername &&
                                $0.requestedReviewers.contains(manager.settings.githubUsername)
                            }
                        )
                        prSection(
                            title: "Other",
                            prs: manager.prs.filter {
                                $0.author != manager.settings.githubUsername &&
                                !$0.requestedReviewers.contains(manager.settings.githubUsername)
                            }
                        )
                    }
                }
                .frame(maxHeight: 380)
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 340)
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "bird.fill")
                .foregroundStyle(.blue)
            Text("Perch")
                .font(.headline)
            Spacer()
            Text(manager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(manager.hasToken ? "No open PRs" : "No token — open Settings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 24)
            Spacer()
        }
    }

    // MARK: - PR section

    @ViewBuilder
    private func prSection(title: String, prs: [PRSnapshot]) -> some View {
        if !prs.isEmpty {
            Section {
                ForEach(prs, id: \.nodeId) { pr in
                    prRow(pr)
                    Divider().padding(.leading, 36)
                }
            } header: {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
        }
    }

    // MARK: - PR row

    private func prRow(_ pr: PRSnapshot) -> some View {
        Button {
            if let url = URL(string: pr.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ciIcon(for: pr.ciStatus)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(pr.repoFullName) #\(pr.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - CI icon

    @ViewBuilder
    private func ciIcon(for ciStatus: CIStatus) -> some View {
        switch ciStatus {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure, .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .pending:
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
        case .unknown:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Settings") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .buttonStyle(.plain)
            .font(.callout)

            Spacer()

            Button("Refresh") {
                Task {
                    await manager.restart()
                }
            }
            .buttonStyle(.plain)
            .font(.callout)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let openSettings = Notification.Name("PerchOpenSettings")
}
