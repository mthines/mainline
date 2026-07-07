import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject private var settings: MainlineSettings
    // Nested ObservableObjects the view reads for live updates. Without observing
    // these directly, mutations (e.g. tapping a scope chip) don't re-render the
    // view until the popover is reopened.
    @ObservedObject private var scopeStore: ScopeStore
    @ObservedObject private var trustLedger: TrustLedgerStore

    init(manager: PRManager) {
        self.manager = manager
        self.settings = manager.settings
        self.scopeStore = manager.scopeStore
        self.trustLedger = manager.trustLedger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            // Global filter row: scope chips + Drafts toggle. These are global
            // filters that apply to BOTH the needs-human bucket and the tabbed
            // browse list, so they sit above the tab selector.
            scopeFilter

            Divider()

            // Global "Needs a Human" bucket — tab-agnostic and cross-cutting
            // (spans authored + review-requested). Fed by `manager.needsHumanPRs`
            // so its header count always equals the menu-bar badge. Lives ABOVE
            // the tabs so switching tabs never changes it.
            needsHumanSection

            Divider()

            // Tab picker governs ONLY the browse list below it.
            tabPicker

            // For-me sub-filter (Direct / Team) — only visible on the For-me tab.
            if settings.selectedTab == .forMe {
                forMeReviewFilterPicker
            }

            // Browse list: PRs for the selected tab + scope + drafts filter.
            content

            Divider()

            footer
        }
        .frame(width: 360)
        .padding(.vertical, 4)
        .onAppear {
            manager.snoozeStore.clearExpired()
            // Delay slightly so user can glance at unread indicators before they clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                manager.markAllSeen()
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                Button("") { cycleScopeBackward() }
                    .keyboardShortcut(KeyEquivalent("["), modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                Button("") { cycleScopeForward() }
                    .keyboardShortcut(KeyEquivalent("]"), modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                Button("") { settings.showDrafts.toggle() }
                    .keyboardShortcut(KeyEquivalent("d"), modifiers: [.command])
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
    }

    // MARK: - Derived data

    /// PRs belonging to the currently selected tab, filtered by scope and (when
    /// `showDrafts` is off) excluding draft PRs. This is the single source of
    /// truth for the visible list, the sections, the Needs-a-Human bucket, and
    /// every count derived below.
    private var visiblePRs: [PRSnapshot] {
        let tabFiltered = manager.prs.filter { $0.tabs.contains(settings.selectedTab) }
        let draftFiltered = settings.showDrafts
            ? tabFiltered
            : tabFiltered.filter { $0.classifiedState != .draft }
        let scopeFiltered: [PRSnapshot]
        if let scope = scopeStore.selectedScope {
            scopeFiltered = draftFiltered.filter { pr in
                switch scope {
                case .org(let o):  return pr.repoFullName.hasPrefix(o + "/")
                case .repo(let r): return pr.repoFullName == r
                }
            }
        } else {
            scopeFiltered = draftFiltered
        }
        // For-me sub-filter: narrow by direct/team review-request source. Only
        // applies on the For-me tab; `.all` (default) is a no-op.
        let sourceFiltered: [PRSnapshot]
        if settings.selectedTab == .forMe, settings.forMeReviewFilter != .all {
            let myLogin = settings.githubUsername
            sourceFiltered = scopeFiltered.filter { pr in
                switch settings.forMeReviewFilter {
                case .all:    return true
                case .direct: return pr.reviewRequestSource(myLogin: myLogin) == .direct
                case .team:   return pr.reviewRequestSource(myLogin: myLogin) == .team
                }
            }
        } else {
            sourceFiltered = scopeFiltered
        }
        return sourceFiltered.sorted(by: PRSnapshot.triageOrder)
    }

    /// Whether a PR should count toward the tab labels, honouring the draft toggle.
    private func countsTowardTabs(_ pr: PRSnapshot) -> Bool {
        settings.showDrafts || pr.classifiedState != .draft
    }

    /// Count for the For-me tab label.
    private var forMeCount: Int {
        manager.prs.filter { $0.tabs.contains(.forMe) && countsTowardTabs($0) }.count
    }

    /// Count for the Created tab label.
    private var createdCount: Int {
        manager.prs.filter { $0.tabs.contains(.created) && countsTowardTabs($0) }.count
    }

    /// Fixed (non-scrolling) chrome the panel always renders around the two
    /// scrolling regions: header, dividers, scope filter, tab picker, optional
    /// For-me sub-filter, and footer. Reserved so the OVERALL panel stays within
    /// the screen guard.
    private static let panelChromeHeight: CGFloat = 260

    /// Dynamic panel content height — the total scrolling budget shared between
    /// the "Needs a Human" box (when expanded) and the tabbed browse list below
    /// it. Bounded so `panelChromeHeight + panelContentHeight` never exceeds the
    /// `screenHeight * 0.80` guard.
    private var panelContentHeight: CGFloat {
        let preferred = CGFloat(settings.panelHeight)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let maxAllowed = screenHeight * 0.80 - Self.panelChromeHeight
        return max(min(preferred, maxAllowed), 280)
    }

    /// Max height for the expanded "Needs a Human" ScrollView. At most half the
    /// content budget, hard-capped at 320, and always leaving the browse list a
    /// usable minimum so the two regions together never exceed the budget.
    /// Collapsed, the section is short (top ~5 rows) regardless.
    private var needsHumanMaxHeight: CGFloat {
        let browseMinimum: CGFloat = 200
        let byBudget = min(panelContentHeight * 0.5, 320)
        // Never reserve so much that the browse list drops below its minimum.
        return min(byBudget, max(panelContentHeight - browseMinimum, 0))
    }

    /// Height budget for the tabbed browse list — the remainder of the content
    /// budget after reserving room for the Needs-a-Human box (only when the
    /// bucket is non-empty). Guarantees needs-human + browse <= budget.
    private var browseListHeight: CGFloat {
        let hasBucket = !manager.needsHumanPRs.isEmpty
        let reserved = hasBucket ? needsHumanMaxHeight : 0
        return panelContentHeight - reserved
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

    // MARK: - For-me review sub-filter (Direct / Team)

    /// Compact segmented control shown only on the For-me tab. Filters the browse
    /// list by review-request source. Persisted in `settings.forMeReviewFilter`.
    private var forMeReviewFilterPicker: some View {
        Picker("Review source", selection: $settings.forMeReviewFilter) {
            ForEach(ForMeReviewFilter.allCases) { filter in
                Text(filter.displayName).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Scope filter

    @ViewBuilder
    private var scopeFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !scopeStore.availableScopes.isEmpty {
                    scopeChip(label: "All", scope: nil)
                    ForEach(scopeStore.availableScopes, id: \.rawValue) { scope in
                        let count = scopeStore.scopeCounts[scope] ?? 0
                        scopeChip(label: "\(scope.displayName) \(count)", scope: scope)
                    }
                    Divider().frame(height: 16)
                }
                draftsChip
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 36)
    }

    /// Compact toggle to include/exclude draft PRs. Mirrors ⌘D shortcut below.
    private var draftsChip: some View {
        Button {
            settings.showDrafts.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: settings.showDrafts ? "eye" : "eye.slash")
                    .font(.caption2)
                Text("Drafts")
                    .font(.caption)
                    .fontWeight(settings.showDrafts ? .semibold : .regular)
            }
            .foregroundStyle(settings.showDrafts ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                settings.showDrafts ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(settings.showDrafts ? "Hide draft PRs (⌘D)" : "Show draft PRs (⌘D)")
    }

    private func scopeChip(label: String, scope: PRScope?) -> some View {
        let isSelected = scopeStore.selectedScope == scope
        return Button {
            scopeStore.selectedScope = scope
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    isSelected ? AnyShapeStyle(.blue.opacity(0.15)) : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scope cycling

    private func cycleScopeForward() {
        let all: [PRScope?] = [nil] + scopeStore.availableScopes
        let current = scopeStore.selectedScope
        if let idx = all.firstIndex(where: { $0 == current }) {
            let next = all[(idx + 1) % all.count]
            scopeStore.selectedScope = next
        } else {
            scopeStore.selectedScope = nil
        }
    }

    private func cycleScopeBackward() {
        let all: [PRScope?] = [nil] + scopeStore.availableScopes
        let current = scopeStore.selectedScope
        if let idx = all.firstIndex(where: { $0 == current }) {
            let prev = all[(idx - 1 + all.count) % all.count]
            scopeStore.selectedScope = prev
        } else {
            scopeStore.selectedScope = nil
        }
    }

    // MARK: - Global "Needs a Human" section

    /// The cross-cutting "Needs a Human" bucket. Tab-agnostic — it shows the
    /// shared scope+draft+conflict-filtered set from PRManager (NOT the
    /// tab-scoped `visiblePRs`), so its header count always equals the menu-bar
    /// badge. Rendered above the tab selector; switching tabs does not change it.
    @ViewBuilder
    private var needsHumanSection: some View {
        let bucket = manager.needsHumanPRs
        if manager.hasToken && (!bucket.isEmpty || manager.handledCount > 0) {
            NeedsHumanView(
                needsHumanPRs: bucket,
                handledCount: manager.handledCount,
                myLogin: settings.githubUsername,
                includeConflicts: settings.includeConflictsInNeedsHuman,
                maxExpandedHeight: needsHumanMaxHeight,
                trustLedger: trustLedger
            )
            .padding(.vertical, 4)
        }
    }

    // MARK: - Content (tabbed browse list)

    @ViewBuilder
    private var content: some View {
        if !manager.hasToken || manager.prs.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The single browse list — keyboard-navigable triage deck
                    // grouped into collapsible per-state sections, scoped to the
                    // selected tab. This does NOT render its own Needs-a-Human
                    // bucket; that global bucket lives above the tabs.
                    TriageDeckView(
                        prs: visiblePRs,
                        manager: manager,
                        settings: settings
                    )
                }
            }
            // Bound the browse list to its share of the content budget so the
            // Needs-a-Human box + browse list + chrome stay within the screen
            // guard. `maxHeight` lets a short list shrink (no forced empty
            // space) while still capping a long one.
            .frame(maxHeight: browseListHeight)
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
