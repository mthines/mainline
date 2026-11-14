import SwiftUI

/// Settings → Issues. Watch level per repo (All issues / Only mine / Off), org-wide actions,
/// and the Inbox switch. Rows are repos we know about (from PRs and issues) plus any the
/// user added by hand.
struct IssuesSettingsView: View {
    @ObservedObject var settings: MainlineSettings
    @ObservedObject var manager: PRManager

    @State private var newRepo = ""

    var body: some View {
        Section("How it works") {
            Label("“Only mine” follows issues you opened, are assigned to, or are mentioned in. “All issues” also surfaces every new issue on that repo. “Off” ignores the repo. Repos default to Only mine.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Inbox") {
            Toggle("Show new issues in Inbox", isOn: Binding(
                get: { settings.showNewIssuesInInbox },
                set: { settings.showNewIssuesInInbox = $0 }
            ))
            Text("Assigned, mentioned and reply issues always show in the Inbox. When this is off, new issues from All-issues repos collapse to one line that points to the Issues tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Organizations") {
            if orgs.isEmpty {
                Text("No organizations yet.").foregroundStyle(.secondary)
            }
            ForEach(orgs, id: \.self) { org in
                HStack {
                    Text(org)
                    Spacer()
                    Menu("Set all repos…") {
                        ForEach(IssueWatchLevel.allCases, id: \.self) { level in
                            Button(level.title) { setOrg(level, org) }
                        }
                    }
                    .fixedSize()
                }
            }
        }

        Section("Repositories") {
            if repos.isEmpty {
                Text("No repositories yet. Add one below.").foregroundStyle(.secondary)
            }
            ForEach(repos, id: \.self) { repo in
                HStack {
                    Text(repo)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.issueWatchLevel(forRepo: repo) },
                        set: { setRepo($0, repo) }
                    )) {
                        ForEach(IssueWatchLevel.allCases, id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            HStack {
                TextField("owner/repo", text: $newRepo)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addRepo() }
                    .disabled(!Self.isValidRepo(newRepo))
            }
        }
    }

    // MARK: Data

    private var repos: [String] {
        var set = Set(settings.issueRepoWatchLevels.keys)
        for issue in manager.issueStore.issues { set.insert(issue.repoFullName.lowercased()) }
        for pr in manager.prs { set.insert(pr.repoFullName.lowercased()) }
        return set.sorted()
    }

    private var orgs: [String] {
        var set = Set(settings.issueOrgWatchLevels.keys)
        for repo in repos {
            if let org = repo.split(separator: "/").first { set.insert(String(org)) }
        }
        return set.sorted()
    }

    static func isValidRepo(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && !text.contains(" ")
    }

    private func setRepo(_ level: IssueWatchLevel, _ repo: String) {
        settings.setIssueWatchLevel(level, forRepo: repo)
        manager.issueStore.refilter()
    }

    private func setOrg(_ level: IssueWatchLevel, _ org: String) {
        settings.setIssueWatchLevel(level, forOrg: org)
        manager.issueStore.refilter()
    }

    private func addRepo() {
        let repo = newRepo.trimmingCharacters(in: .whitespaces)
        guard Self.isValidRepo(repo) else { return }
        settings.setIssueWatchLevel(settings.issueWatchLevel(forRepo: repo), forRepo: repo)
        newRepo = ""
    }
}
