import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject private var settings: MainlineSettings

    init(manager: PRManager) {
        self.manager = manager
        self.settings = manager.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            tabPicker

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: 340)
        .padding(.vertical, 4)
        .onAppear {
            manager.snoozeStore.clearExpired()
        }
    }

    // MARK: - Derived data

    /// PRs belonging to the currently selected tab.
    private var visiblePRs: [PRSnapshot] {
        manager.prs.filter { $0.tabs.contains(settings.selectedTab) }
    }

    /// Count for the For-me tab label.
    private var forMeCount: Int {
        manager.prs.filter { $0.tabs.contains(.forMe) }.count
    }

    /// Count for the Created tab label.
    private var createdCount: Int {
        manager.prs.filter { $0.tabs.contains(.created) }.count
    }

    /// Sections in canonical order, each with its PRs, excluding empty ones.
    private var sections: [(state: PRState, prs: [PRSnapshot])] {
        let grouped = Dictionary(grouping: visiblePRs, by: { $0.classifiedState })
        return PRState.allCases
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { state in
                guard let prs = grouped[state], !prs.isEmpty else { return nil }
                return (state, prs.sorted { $0.updatedAt > $1.updatedAt })
            }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(.blue)
            Text("Mainline")
                .font(.headline)
            Spacer()
            // Error state: red + tappable to open Settings (AC-19)
            if manager.tokenInvalid {
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                } label: {
                    Text("Token invalid — tap to fix")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
                .buttonStyle(.plain)
            } else {
                Text(manager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Tab picker (AC-18: labels show counts)

    private var tabPicker: some View {
        Picker("Reviews", selection: $settings.selectedTab) {
            ForEach(ReviewTab.allCases) { tab in
                Text(tabLabel(for: tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tabLabel(for tab: ReviewTab) -> String {
        switch tab {
        case .forMe:   return forMeCount > 0   ? "For me (\(forMeCount))"     : tab.title
        case .created: return createdCount > 0 ? "Created (\(createdCount))" : tab.title
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !manager.hasToken || manager.prs.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Layer C: Needs-a-Human bucket at top
                    if !visiblePRs.isEmpty {
                        NeedsHumanView(
                            prs: visiblePRs,
                            myLogin: settings.githubUsername,
                            trustLedger: manager.trustLedger
                        )
                        Divider()
                    }

                    // Layer B: keyboard triage deck
                    TriageDeckView(
                        prs: visiblePRs,
                        manager: manager,
                        settings: settings
                    )

                    ForEach(sections, id: \.state) { section in
                        sectionView(state: section.state, prs: section.prs)
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }

    // MARK: - Empty state (AC-23)

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                emptyStateIcon
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if manager.hasToken {
                    Text("If you expected PRs here, your token may lack repo/read:org scope or SSO authorization. Try \"Import from gh\".")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
            }
            .padding(.vertical, 24)
            Spacer()
        }
    }

    @ViewBuilder
    private var emptyStateIcon: some View {
        if !manager.hasToken {
            // AC-23: no token → key icon
            Image(systemName: "key.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        } else if manager.tokenInvalid {
            // AC-23: invalid token → exclamationmark.circle
            Image(systemName: "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(Color(nsColor: .systemRed))
        } else if manager.isRefreshing {
            // AC-23: polling → ProgressView
            ProgressView()
                .controlSize(.regular)
        } else {
            // AC-23: genuinely empty → checkmark
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyMessage: String {
        if !manager.hasToken { return "No token — open Settings" }
        if manager.tokenInvalid { return "Token invalid — tap to fix" }
        switch settings.selectedTab {
        case .forMe:   return "Nothing to review"
        case .created: return "No PRs created"
        }
    }

    // MARK: - Section (collapsible, persisted — AC-22)

    @ViewBuilder
    private func sectionView(state: PRState, prs: [PRSnapshot]) -> some View {
        DisclosureGroup(
            isExpanded: expansionBinding(for: state)
        ) {
            ForEach(prs, id: \.nodeId) { pr in
                prRow(pr)
                Divider().padding(.leading, 36)
            }
        } label: {
            HStack(spacing: 6) {
                Text(state.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("\(prs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// Collapse state persisted to MainlineSettings (AC-22).
    private func expansionBinding(for state: PRState) -> Binding<Bool> {
        Binding(
            get: { !settings.collapsedSections.contains(state) },
            set: { expanded in
                var collapsed = settings.collapsedSections
                if expanded {
                    collapsed.remove(state)
                } else {
                    collapsed.insert(state)
                }
                settings.collapsedSections = collapsed
            }
        )
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
                    HStack(spacing: 4) {
                        Text("\(pr.repoFullName) #\(pr.number)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Layer D: trust badge
                        TrustBadgeView(tier: manager.trustLedger.tier(for: pr.author))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - CI icon (AC-17: accessibilityLabel on every state)

    @ViewBuilder
    private func ciIcon(for ciStatus: CIStatus) -> some View {
        switch ciStatus {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("CI passed")
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("CI failed")
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("CI error")
        case .pending:
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("CI pending")
        case .unknown:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .accessibilityLabel("CI status unknown")
        }
    }

    // MARK: - Footer (AC-21: 44pt hit targets, Quit separated)

    private var footer: some View {
        HStack(spacing: 0) {
            Button("Settings") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)

            Spacer()

            // AC-20: Refresh shows spinner + disabled during refresh
            Button {
                Task { await manager.triggerSingleRefresh() }
            } label: {
                if manager.isRefreshing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing")
                            .font(.callout)
                    }
                } else {
                    Text("Refresh")
                        .font(.callout)
                }
            }
            .buttonStyle(.plain)
            .disabled(manager.isRefreshing)
            .frame(minHeight: 44)
            .padding(.horizontal, 8)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 0)
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let openSettings = Notification.Name("MainlineOpenSettings")
}
