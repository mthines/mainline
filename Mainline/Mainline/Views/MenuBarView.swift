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

    /// Whether the "Needs a Human" bucket is expanded. Lifted up from
    /// `NeedsHumanView` so the height math below can react to expansion: collapsed
    /// hands the whole budget to the browse list; expanded gives the needs-human
    /// list a real, scrolling height. Collapsed by default.
    @State private var needsHumanExpanded = false

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

            // Badge explainer: mirrors the menu-bar icon (same glyph + tint) and
            // spells out what the number means, so the panel ties the icon count
            // to the selected scope/metric. Counted in `chromeReserve`.
            badgeExplainer

            Divider()

            // Tab picker is the PRIMARY axis — it sits at the top and EVERYTHING
            // below it (scope filter, Needs-a-Human, browse list) respects the
            // selected tab.
            tabPicker

            // For-me sub-filter (Direct / Team) — only visible on the For-me tab.
            if settings.selectedTab == .forMe {
                forMeReviewFilterPicker
            }

            Divider()

            // Filter row: scope chips + Drafts toggle. Applies within the
            // selected tab.
            scopeFilter

            Divider()

            // "Needs a Human" bucket — GLOBAL (tab-agnostic): its header count and
            // rows derive from `manager.needsHumanPRs` (scope + drafts + conflicts
            // applied) so the count always equals the menu-bar badge, regardless of
            // the active tab. Collapsed by default so a noisy bucket (e.g.
            // dependabot chores with red CI) never blocks the browse list below it.
            needsHumanSection

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

    // MARK: - Height budget
    //
    // A MenuBarExtra(.window) popover has NO external height constraint: it sizes
    // to its SwiftUI content and macOS clips (does NOT scroll) anything past the
    // screen. So we bound the scrollable regions to the REAL available on-screen
    // height. The invariant we maintain:
    //
    //     chromeReserve + needsHumanHeight + browseHeight <= available <= screen
    //
    // where `needsHumanHeight` is 0 when the bucket is collapsed (or empty) and
    // the expanded value otherwise. When collapsed the browse list receives the
    // entire post-chrome budget; when expanded the needs-human list takes the
    // majority and the browse list keeps a usable floor.
    //
    // `chromeReserve` counts every always-present fixed element conservatively
    // (over-, never under-counting — under-counting is what caused the overrun /
    // clipped footer). The collapsed needs-human HEADER (40pt) is part of
    // `chromeReserve` regardless of expansion. Both ScrollViews get a FIXED
    // `.frame(height:)`, not `maxHeight`, so overflow always scrolls and the
    // total declared height stays within `available`.

    /// Conservative on-screen budget: the smaller of the user's preferred panel
    /// height and the real space below the menu bar (visibleFrame minus a small
    /// guard for the menu bar / popover arrow).
    private var availableHeight: CGFloat {
        min(CGFloat(settings.panelHeight),
            (NSScreen.main?.visibleFrame.height ?? 800) - 40)
    }

    /// Fixed reserve for the always-present (non-scrolling) chrome. Summed from
    /// the real elements so it is not under-counted:
    ///   header ~44 + badge explainer ~22 + tab picker ~44 + scope/drafts row ~44 +
    ///   collapsed needs-human header ~40 + footer ~48 + dividers/padding ~30
    ///   (+ For-me sub-filter ~36 only when the For-me tab is active).
    private var chromeReserve: CGFloat {
        let base: CGFloat = 44 + 22 + 44 + 44 + 40 + 48 + 30   // = 272
        let forMeFilter: CGFloat = settings.selectedTab == .forMe ? 36 : 0
        return base + forMeFilter
    }

    /// Post-chrome budget: the space left after the always-present fixed chrome.
    /// Shared basis for both scroll regions.
    private var postChrome: CGFloat {
        max(availableHeight - chromeReserve, 0)
    }

    /// Height for the "Needs a Human" ScrollView.
    ///
    /// - Collapsed, empty, or no token: 0 — the section contributes only its
    ///   header (already counted in `chromeReserve`) and the browse list gets the
    ///   whole `postChrome` budget.
    /// - Expanded (with items): the MAJORITY of the budget — ~60% of `postChrome`,
    ///   clamped to a floor of 160 (so it is never a zero/one-pixel sliver) and a
    ///   ceiling of `postChrome - 150` (so the browse list keeps its 150pt floor).
    ///   The floor itself is clamped not to exceed the ceiling on very short
    ///   screens, and a hard 140pt minimum guarantees a genuinely useful list.
    private var needsHumanMaxHeight: CGFloat {
        let hasBucket = manager.hasToken && !globalNeedsHuman.isEmpty
        guard hasBucket && needsHumanExpanded else { return 0 }

        let target = (postChrome * 0.6).rounded()
        let ceiling = max(postChrome - 150, 160)
        let floor: CGFloat = 160
        let clamped = min(max(target, floor), ceiling)
        // Never a sliver: guarantee at least ~140pt whenever expanded with items.
        return max(clamped, min(140, postChrome))
    }

    /// FIXED height for the tabbed browse ScrollView. Gets the entire post-chrome
    /// budget when the needs-human list is collapsed/empty; otherwise `postChrome`
    /// minus the expanded needs-human height. Floored at 150 so it stays usable
    /// even when the bucket is expanded, and at 200 when it has the whole budget.
    /// A fixed height (not maxHeight) guarantees a taller list scrolls and the
    /// footer stays on-screen. Together with `needsHumanMaxHeight` this preserves
    /// `needsHumanMaxHeight + browseHeight <= postChrome` whenever the budget
    /// allows (both floors can only grow the panel on very short screens, where
    /// the browse list's own ScrollView still scrolls).
    private var browseHeight: CGFloat {
        let nh = needsHumanMaxHeight
        if nh <= 0 {
            return max(200, postChrome)
        }
        return max(150, postChrome - nh)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(.blue)
            Text("Mainline")
                .font(.headline)
                .fixedSize()
            Spacer(minLength: 8)
            // Error state: red + tappable to open Settings (AC-19)
            if manager.tokenInvalid {
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                } label: {
                    Text("Token invalid — tap to fix")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
            } else {
                Text(manager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Settings gear — always-visible fixed chrome, far right. Reachable
            // even when the panel is very tall, since the header never scrolls.
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .help("Settings")
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Badge explainer

    /// Compact one-line caption that mirrors the menu-bar badge: same glyph + tint
    /// as `MenuBarIconView`, followed by `manager.badgeExplanation`. Explains what
    /// the icon number counts (e.g. "◐ 115 open PRs in dash0hq"). Uses the badge's
    /// symbol/tint without the count text, so the number appears once (in the
    /// explanation string) and never disagrees with the icon.
    private var badgeExplainer: some View {
        let badge = manager.menuBarBadge
        return HStack(spacing: 6) {
            Image(systemName: badge.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(badgeTint(for: badge))
                .font(.caption)
            Text(manager.badgeExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help(manager.badgeExplanation)
    }

    /// Tint mirroring `MenuBarIconView.iconColor`: clear/neutral → secondary,
    /// attention → orange, blocker → red.
    private func badgeTint(for badge: MenuBarBadge) -> Color {
        guard badge.count != nil else { return .secondary }
        switch badge {
        case .neutral:   return .secondary
        case .attention: return Color(nsColor: .systemOrange)
        case .blocker:   return Color(nsColor: .systemRed)
        }
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

    // MARK: - "Needs a Human" section (GLOBAL / tab-agnostic)

    /// The GLOBAL "Needs a Human" bucket — sourced from `manager.needsHumanPRs`
    /// (scope + drafts + conflicts applied, but NOT tab-scoped). Using the same
    /// set the badge reads guarantees the collapsed "Needs a Human · N" header
    /// count equals `PRManager.needsHumanCount` / `menuBarBadge` on EITHER tab.
    private var globalNeedsHuman: [PRSnapshot] {
        manager.needsHumanPRs
    }

    /// The GLOBAL "Needs a Human" bucket. Collapsed by default (see
    /// `NeedsHumanView`) so a noisy bucket never blocks the browse list below it.
    /// Both `needsHumanPRs` and `handledCount` are tab-agnostic (from the manager)
    /// so the header count matches the menu-bar badge on every tab.
    @ViewBuilder
    private var needsHumanSection: some View {
        let bucket = globalNeedsHuman
        if manager.hasToken && !bucket.isEmpty {
            NeedsHumanView(
                needsHumanPRs: bucket,
                handledCount: manager.handledCount,
                myLogin: settings.githubUsername,
                includeConflicts: settings.includeConflictsInNeedsHuman,
                maxExpandedHeight: needsHumanMaxHeight,
                metrics: RowMetrics.forCompact(settings.compactRows),
                trustLedger: trustLedger,
                expanded: $needsHumanExpanded
            )
            .padding(.vertical, 4)

            Divider()
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
            // FIXED height (not maxHeight): guarantees a taller list scrolls and
            // the footer below stays on-screen. Sized so
            // chromeReserve + needsHumanHeight + browseHeight <= available <= screen.
            .frame(height: browseHeight)
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
            .padding(.horizontal, 12)

            Spacer()

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
