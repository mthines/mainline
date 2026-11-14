import SwiftUI
import AppKit

// MARK: - Shortcut matching (shared with the deck)

/// True when `event` is the user's configured binding for `shortcut`: the base key
/// (ignoring modifiers) AND the masked modifier set must both match. The deck and the
/// Issues tab read bindings through this one function so they can never disagree.
func inAppShortcutMatches(_ shortcut: InAppShortcut, event: NSEvent, settings: MainlineSettings) -> Bool {
    let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
    let binding = settings.shortcutBindings.binding(for: shortcut)
    guard !binding.key.isEmpty, chars == binding.key else { return false }
    let mods = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .intersection(ShortcutBinding.relevantModifierMask)
    return mods == binding.modifierFlags
}

// MARK: - Menu shortcut glyphs

extension ShortcutBinding {
    /// The SwiftUI key for a single-character binding; nil for an unbound shortcut.
    var menuKeyEquivalent: KeyEquivalent? {
        guard key.count == 1, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }

    var menuModifiers: EventModifiers {
        var out: EventModifiers = []
        let flags = modifierFlags
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.option) { out.insert(.option) }
        return out
    }
}

extension View {
    /// Shows the user's configured key for `shortcut` at the trailing edge of a menu item,
    /// the way a native menu does. It follows Settings → Keyboard, and an unbound
    /// shortcut adds nothing. Only meaningful on a menu button: the shortcut is live
    /// while the menu is open, and the deck's own key handler does the real work.
    @ViewBuilder
    func menuShortcut(_ shortcut: InAppShortcut, _ settings: MainlineSettings) -> some View {
        let binding = settings.shortcutBindings.binding(for: shortcut)
        if let key = binding.menuKeyEquivalent {
            self.keyboardShortcut(key, modifiers: binding.menuModifiers)
        } else {
            self
        }
    }
}

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
///
/// Interaction mirrors a PR deck row: hovering selects it (`onHoverSelect`), the selected
/// row gets the same accent tint + leading bar (`isFocused`), and a capsule of quick
/// actions appears at its trailing edge.
struct IssueRowView: View {
    let issue: IssueSnapshot
    let isUnread: Bool
    let isMuted: Bool
    var isArchived: Bool = false
    var isFocused: Bool = false
    var onHoverSelect: (() -> Void)? = nil
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
                        // `verbatim`: an Int interpolated into a localized Text gets a
                        // thousands separator ("#2.019").
                        Text(verbatim: "#\(issue.number)")
                        if let reason = reasonText { Text(verbatim: "· \(reason)") }
                        Text(verbatim: "· \(Self.ago(issue.updatedAt))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if isFocused { hoverActions }
            }
            .background(isFocused ? Color.accentColor.opacity(0.22) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isFocused ? Color.accentColor : Color.clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { onHoverSelect?() }
        }
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

    // MARK: Quick actions

    private var hoverActions: some View {
        HStack(spacing: 4) {
            if isArchived {
                actionButton("Restore", icon: "arrow.uturn.backward") {
                    manager.issueStore.unarchive(issue.nodeId)
                }
            } else {
                actionButton("Archive", icon: "archivebox") {
                    manager.issueStore.archive(issue)
                }
            }
            actionButton(isMuted ? "Unmute" : "Mute", icon: isMuted ? "bell" : "bell.slash") {
                manager.issueStore.toggleMute(issue.nodeId)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 4)
        .fixedSize()
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button("Open on GitHub") { manager.openIssue(issue) }
            .keyboardShortcut(.return, modifiers: [])
        Button("Mark as seen") { manager.markIssueSeen(issue) }
            .menuShortcut(.markSeen, settings)
            .disabled(!isUnread)
        Divider()
        if isArchived {
            Button("Restore from archive") { manager.issueStore.unarchive(issue.nodeId) }
                .menuShortcut(.dismiss, settings)
        } else {
            Button("Archive (back on new activity)") { manager.issueStore.archive(issue) }
                .menuShortcut(.dismiss, settings)
        }
        Button(isMuted ? "Unmute" : "Mute for good") { manager.issueStore.toggleMute(issue.nodeId) }
            .menuShortcut(.toggleMute, settings)
        Divider()
        Menu("Watch \(issue.repoFullName)") {
            IssueWatchLevelMenuItems(repo: issue.repoFullName, settings: settings, issueStore: manager.issueStore)
        }
        Divider()
        Button("Copy link") { Self.copyLink(issue) }
            .menuShortcut(.copyBranch, settings)
    }

    static func copyLink(_ issue: IssueSnapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.url, forType: .string)
    }

    private var reasonText: String? {
        let me = settings.githubUsername
        if issue.isAssigned(to: me) { return "assigned to you" }
        if issue.isAuthored(by: me) { return issue.awaitingMyReply(login: me) ? "new reply" : "yours" }
        if issue.mentionsMe { return "mentioned you" }
        if issue.commentCount > 0 {
            return issue.commentCount == 1 ? "1 comment" : "\(issue.commentCount) comments"
        }
        return nil
    }

    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Issues tab

/// The Issues tab body: Needs you, Assigned, Waiting on reporter, then Muted and
/// Archived (both collapsed). Rows behave like deck rows: hover selects, J/K moves,
/// ↵ opens, N marks seen, X archives, Q mutes, C copies the link.
struct IssuesView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject var settings: MainlineSettings
    @State private var mutedExpanded = false
    @State private var archivedExpanded = false
    @State private var selectedIndex = 0

    private var sections: [IssueSection: [IssueSnapshot]] {
        Self.sections(manager.visibleIssues, myLogin: settings.githubUsername,
                      muted: Set(settings.mutedIssueIds))
    }

    private var archivedList: [IssueSnapshot] { manager.archivedIssues }

    /// The keyboard order: exactly the rows on screen, top to bottom.
    private func focusOrder(_ sections: [IssueSection: [IssueSnapshot]]) -> [IssueSnapshot] {
        var list: [IssueSnapshot] = []
        for section in IssueSection.allCases where section != .muted {
            list += sections[section] ?? []
        }
        if mutedExpanded { list += sections[.muted] ?? [] }
        if archivedExpanded { list += archivedList }
        return list
    }

    var body: some View {
        let sections = self.sections
        let order = focusOrder(sections)
        let indexOf = Dictionary(order.enumerated().map { ($1.nodeId, $0) }, uniquingKeysWith: { a, _ in a })
        let archived = archivedList
        VStack(alignment: .leading, spacing: 0) {
            ForEach(IssueSection.allCases, id: \.rawValue) { section in
                if let items = sections[section], !items.isEmpty {
                    if section == .muted {
                        collapsibleHeader("eye.slash", IssueSection.muted.title, count: items.count,
                                          expanded: $mutedExpanded)
                        if mutedExpanded { rows(items, muted: true, archived: false, indexOf: indexOf) }
                    } else {
                        header(section.title, count: items.count)
                        rows(items, muted: false, archived: false, indexOf: indexOf)
                    }
                }
            }
            if !archived.isEmpty {
                collapsibleHeader("archivebox", "Archived", count: archived.count, expanded: $archivedExpanded)
                if archivedExpanded {
                    rows(archived, muted: false, archived: true, indexOf: indexOf)
                }
            }
            if order.isEmpty && archived.isEmpty {
                Text("Nothing to show")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .background(KeyCaptureView(handler: { handleKey($0, order: order) }, onDismiss: {}))
        .onChange(of: order.map(\.nodeId)) { ids in
            if selectedIndex >= ids.count { selectedIndex = max(ids.count - 1, 0) }
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

    // MARK: Keys

    private func handleKey(_ event: NSEvent, order: [IssueSnapshot]) -> NSEvent? {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let noMods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(ShortcutBinding.relevantModifierMask)
            .isEmpty
        func match(_ shortcut: InAppShortcut) -> Bool {
            inAppShortcutMatches(shortcut, event: event, settings: settings)
        }

        if match(.navigateDown) || (chars == "\u{F701}" && noMods) {
            selectedIndex = min(selectedIndex + 1, max(order.count - 1, 0))
            return nil
        }
        if match(.navigateUp) || (chars == "\u{F700}" && noMods) {
            selectedIndex = max(selectedIndex - 1, 0)
            return nil
        }
        guard selectedIndex < order.count else { return event }
        let issue = order[selectedIndex]
        let store = manager.issueStore

        if event.keyCode == 36 {   // Return
            manager.openIssue(issue)
            return nil
        }
        if match(.markSeen) { manager.markIssueSeen(issue); return nil }
        if match(.dismiss) {
            if store.isArchived(issue) { store.unarchive(issue.nodeId) } else { store.archive(issue) }
            return nil
        }
        if match(.toggleMute) { store.toggleMute(issue.nodeId); return nil }
        if match(.copyBranch) { IssueRowView.copyLink(issue); return nil }
        return event
    }

    // MARK: Layout

    private func rows(_ items: [IssueSnapshot], muted: Bool, archived: Bool,
                      indexOf: [String: Int]) -> some View {
        ForEach(items) { issue in
            let index = indexOf[issue.nodeId]
            IssueRowView(issue: issue, isUnread: manager.issueStore.isUnread(issue.nodeId),
                         isMuted: muted, isArchived: archived,
                         isFocused: index != nil && index == selectedIndex,
                         onHoverSelect: { if let index { selectedIndex = index } },
                         manager: manager, settings: settings)
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

    private func collapsibleHeader(_ icon: String, _ title: String, count: Int,
                                   expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
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
