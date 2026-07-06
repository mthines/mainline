import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject private var settings: PerchSettings

    /// Which sections start collapsed. Sections not in the set are expanded.
    @State private var collapsedSections: Set<PRState> = []

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
    }

    // MARK: - Derived data

    /// PRs belonging to the currently selected tab.
    private var visiblePRs: [PRSnapshot] {
        manager.prs.filter { $0.tabs.contains(settings.selectedTab) }
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

    // MARK: - Tab picker

    private var tabPicker: some View {
        Picker("Reviews", selection: $settings.selectedTab) {
            ForEach(ReviewTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if sections.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.state) { section in
                        sectionView(state: section.state, prs: section.prs)
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 24)
            Spacer()
        }
    }

    private var emptyMessage: String {
        if !manager.hasToken { return "No token — open Settings" }
        switch settings.selectedTab {
        case .forMe:   return "Nothing to review"
        case .created: return "No PRs created"
        }
    }

    // MARK: - Section (collapsible)

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

    private func expansionBinding(for state: PRState) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(state) },
            set: { expanded in
                if expanded {
                    collapsedSections.remove(state)
                } else {
                    collapsedSections.insert(state)
                }
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
