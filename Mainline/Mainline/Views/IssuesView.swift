import SwiftUI
import AppKit

// MARK: - Watch-level menu items

/// The three watch levels for one repo (current one checked), plus an org-wide action.
/// Shared by the issue row's context menu, the repo chip's context menu and Settings.
struct IssueWatchLevelMenuItems: View {
    let repo: String
    @ObservedObject var settings: MainlineSettings
    let issueStore: IssueStore

    private var org: String { repo.split(separator: "/").first.map(String.init) ?? repo }

    var body: some View {
        let current = settings.issueWatchLevel(forRepo: repo)
        ForEach(IssueWatchLevel.allCases, id: \.self) { level in
            Button {
                settings.setIssueWatchLevel(level, forRepo: repo)
                issueStore.refilter()
            } label: {
                if level == current {
                    Label(level.title, systemImage: "checkmark")
                } else {
                    Text(level.title)
                }
            }
        }
        Divider()
        Menu("All repos in \(org)") {
            ForEach(IssueWatchLevel.allCases, id: \.self) { level in
                Button(level.title) {
                    settings.setIssueWatchLevel(level, forOrg: org)
                    issueStore.refilter()
                }
            }
        }
    }
}

// MARK: - Row

/// One issue row. Clicking opens it on GitHub and marks it seen (the single read-state set).
struct IssueRowView: View {
    let issue: IssueSnapshot
    let isUnread: Bool
    let isMuted: Bool
    @ObservedObject var manager: PRManager
    @ObservedObject var settings: MainlineSettings

    var body: some View {
        Button {
            manager.openIssue(issue)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(isUnread ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(.callout)
                        .fontWeight(isUnread ? .semibold : .regular)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        repoChip
                        Text("#\(issue.number)")
                        if let reason = reasonText { Text("· \(reason)") }
                        Text("· \(Self.ago(issue.updatedAt))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowMenu }
    }

    private var repoChip: some View {
        Text(issue.repoFullName)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help("Right-click to change how this repo's issues are watched")
            .contextMenu {
                IssueWatchLevelMenuItems(repo: issue.repoFullName, settings: settings, issueStore: manager.issueStore)
            }
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button("Open on GitHub") { manager.openIssue(issue) }
        Button("Mark as seen") { manager.markIssueSeen(issue) }
            .disabled(!isUnread)
        Button(isMuted ? "Unmute" : "Mute") { manager.issueStore.toggleMute(issue.nodeId) }
        Divider()
        Menu("Watch \(issue.repoFullName)") {
            IssueWatchLevelMenuItems(repo: issue.repoFullName, settings: settings, issueStore: manager.issueStore)
        }
        Divider()
        Button("Copy link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(issue.url, forType: .string)
        }
    }

    private var reasonText: String? {
        let me = settings.githubUsername
        if issue.isAssigned(to: me) { return "assigned to you" }
        if issue.isAuthored(by: me) { return issue.awaitingMyReply(login: me) ? "new reply" : "yours" }
        if issue.mentionsMe { return "mentioned you" }
        if issue.commentCount > 0 { return "\(issue.commentCount) comments" }
        return nil
    }

    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Issues tab

/// The Issues tab body: Needs you, Assigned, Waiting on reporter, then Muted (collapsed).
struct IssuesView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject var settings: MainlineSettings
    @State private var mutedExpanded = false

    var body: some View {
        let sections = Self.sections(manager.issueStore.issues, myLogin: settings.githubUsername,
                                     muted: Set(settings.mutedIssueIds))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(IssueSection.allCases, id: \.rawValue) { section in
                if let items = sections[section], !items.isEmpty {
                    if section == .muted {
                        mutedHeader(count: items.count)
                        if mutedExpanded { rows(items, muted: true) }
                    } else {
                        header(section.title, count: items.count)
                        rows(items, muted: false)
                    }
                }
            }
        }
    }

    static func sections(_ issues: [IssueSnapshot], myLogin: String,
                         muted: Set<String>) -> [IssueSection: [IssueSnapshot]] {
        var out: [IssueSection: [IssueSnapshot]] = [:]
        for issue in issues {
            let section = IssueClassifier.section(for: issue, myLogin: myLogin, muted: muted.contains(issue.nodeId))
            out[section, default: []].append(issue)
        }
        return out
    }

    private func rows(_ items: [IssueSnapshot], muted: Bool) -> some View {
        ForEach(items) { issue in
            IssueRowView(issue: issue, isUnread: manager.issueStore.isUnread(issue.nodeId),
                         isMuted: muted, manager: manager, settings: settings)
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).fontWeight(.bold)
            Text("\(count)")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func mutedHeader(count: Int) -> some View {
        Button { mutedExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary)
                Text(IssueSection.muted.title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Image(systemName: mutedExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
