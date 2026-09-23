import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject private var settings: MainlineSettings
    // Nested ObservableObjects the view reads for live updates. Without observing
    // these directly, mutations (e.g. tapping a scope chip) don't re-render the
    // view until the popover is reopened.
    @ObservedObject private var scopeStore: ScopeStore

    /// Natural (unclamped) height of the single scrollable body — the tabbed
    /// browse deck. Measured via a `GeometryReader` background on the body content
    /// and reported through `BodyHeightKey`. The panel sizes the scroll region to
    /// this value clamped to `regionCap`, so it follows content up to the max.
    /// `0` until first measured.
    @State private var measuredBodyHeight: CGFloat = 0

    /// Keyboard focus for the in-app search field. Driven by `manager.searchFocusToken`
    /// (open/re-focus) and cleared on Return (hand focus back to the deck) / close.
    @FocusState private var searchFieldFocused: Bool

    /// Local key monitor, installed only while the search field is focused, that
    /// intercepts the Down arrow before the field editor handles it. A single-line
    /// `NSTextField` treats Down as "move cursor to end of line" and consumes it, so
    /// SwiftUI's `.onMoveCommand` never sees it — the monitor is the only reliable way
    /// to catch Down and hand focus to the results instead. Scoped to while-focused so
    /// it touches nothing else, and it only ever acts on the Down key.
    @State private var searchDownKeyMonitor: Any?

    init(manager: PRManager) {
        self.manager = manager
        self.settings = manager.settings
        self.scopeStore = manager.scopeStore
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
            // below it (scope filter, browse list) respects the selected tab.
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

            // In-app search field — shown only while search is active (opened via the
            // `search` shortcut). Filters across the whole tab (ignoring scope/drafts).
            if manager.searchActive {
                searchBar
                Divider()
            }

            // The SINGLE scrollable body: the tabbed browse deck, grouped by
            // actionability (Needs attention → Ready to merge → Waiting → Draft →
            // Merged → Closed). One ScrollView, sized to its MEASURED content
            // clamped to `regionCap`, so the panel follows content up to the max and
            // scrolls only when it overflows. Replaces the old two independently-
            // fixed nested ScrollViews (the crash source) AND the separate top
            // "Needs a Human" bucket (which duplicated the "Needs attention" group).
            scrollableBody
                // Undo toast stack — overlaid at the TOP of the scroll region (just
                // below the header/filters, well clear of the settings cog) so it
                // never lands under the pointer when muting rows at the BOTTOM of the
                // list, which is where triage most often happens. Slides in from the
                // top to match its new anchor.
                .overlay(alignment: .top) {
                    VStack(spacing: 6) {
                        if let toast = manager.infoToast {
                            InfoToastView(toast: toast) { manager.infoToast = nil }
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if !manager.undoEntries.isEmpty {
                            UndoToastView(entries: $manager.undoEntries)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
                .animation(.easeInOut(duration: 0.2), value: manager.undoEntries.count)
                .animation(.easeInOut(duration: 0.2), value: manager.infoToast)

            Divider()

            keyboardLegend

            Divider()

            footer
        }
        .frame(width: 400)
        .padding(.vertical, 4)
        // Solid backdrop between the system material and the content, at the
        // user's chosen strength (Settings → Appearance → Panel). Drawn BEHIND
        // everything above and ABOVE the window's material, so it is what the
        // deck's text sits on. No-op at the default 0.
        .background(panelBackdrop)
        .onPreferenceChange(BodyHeightKey.self) { newValue in
            // Store the measured natural body height so the scroll region can size
            // to content up to the cap. Guarded finite/non-negative at the source
            // (bodyHeightReader); clamp again defensively here.
            let v = newValue.isFinite ? max(0, newValue) : 0
            // Apply on the NEXT runloop tick, not synchronously inside this layout
            // pass: writing the state here can re-enter layout → re-measure → loop.
            // Combined with instant (non-animated) section toggles, this keeps the
            // measured-height → frame path from ping-ponging (the expand freeze).
            guard abs(v - measuredBodyHeight) > 1 else { return }
            DispatchQueue.main.async { measuredBodyHeight = v }
        }
        .onAppear {
            manager.snoozeStore.clearExpired()
            // Delay slightly so user can glance at unread indicators before they clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                manager.markAllSeen()
            }
        }
        // Focus the search field whenever the search key requests it (token bump);
        // release focus when search closes so the deck's key capture resumes.
        // The field is rendered conditionally on `searchActive`, so on the SAME
        // state change that opens search the TextField is not yet in the view
        // tree — assigning focus synchronously would be dropped. Defer one runloop
        // tick so the field exists before it is focused.
        .onChange(of: manager.searchFocusToken) { _ in
            guard manager.searchActive else { return }
            DispatchQueue.main.async { searchFieldFocused = true }
        }
        .onChange(of: manager.searchActive) { active in
            if active {
                DispatchQueue.main.async { searchFieldFocused = true }
            } else {
                searchFieldFocused = false
            }
        }
        // Install the Down-arrow monitor only while the field holds focus, so the
        // key can hand off to the results instead of moving the cursor to line-end.
        .onChange(of: searchFieldFocused) { focused in
            if focused { installSearchDownMonitor() } else { removeSearchDownMonitor() }
        }
        .onDisappear { removeSearchDownMonitor() }
        // A pasted PR URL for a PR outside the current tab has no local match; fetch
        // it on demand so search can still resolve it. No-op for bare numbers / text.
        .onChange(of: manager.searchQuery) { query in
            Task { await manager.resolveSearchTarget(for: query) }
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
        // Peek overlay — presented at the PANEL level (not inside the scrolling
        // deck) so the card can use the full popover height. Target lives on
        // `manager.peekPR`; the deck only sets it.
        .overlay {
            if let pr = manager.peekPR {
                // Top-aligned, not centered: the card sizes to each PR's content, so
                // a centered card would shift vertically as you step through PRs with
                // J/K and the title/info would jump. Pinning to the top keeps the
                // header and glance rows anchored in place while stepping.
                ZStack(alignment: .top) {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { manager.peekPR = nil }
                    PRPeekView(
                        pr: pr,
                        client: manager.client,
                        isPresented: Binding(
                            get: { manager.peekPR != nil },
                            set: { if !$0 { manager.peekPR = nil } }
                        ),
                        settings: settings,
                        // Cap only — the card sizes to its content and grows to at
                        // most this, so short PRs render a compact card instead of
                        // filling the panel.
                        maxHeight: peekHeight
                    )
                    // NB: no `.id(pr.nodeId)` here on purpose. Tagging identity to the
                    // node id recreated the view on every J/K step, which re-fired the
                    // insertion transition below — so the fade/scale replayed on each
                    // navigation. Keeping one stable identity means stepping only swaps
                    // the card's CONTENT (no re-animation); PRPeekView reloads its
                    // files list off `.task(id: pr.nodeId)` instead.
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                .zIndex(10)
            }
        }
        // Animate only the OPEN/CLOSE boundary (nil ↔ present), not PR-to-PR steps.
        // Keying on the node id animated every navigation and replayed the fade.
        .animation(.easeInOut(duration: 0.12), value: manager.peekPR != nil)
    }

    // MARK: - Panel backdrop

    /// The opaque layer painted over the popover's system material, at
    /// `settings.panelBackgroundOpacity` (Settings → Appearance → Panel).
    ///
    /// The MenuBarExtra window's material samples whatever is behind it, so over a
    /// text-heavy window or a busy wallpaper the deck's own text competes with the
    /// bleed-through and becomes hard to read (issue #41). The material itself is
    /// AppKit's, and how translucent it is differs by macOS version (notably the
    /// macOS 26 glass look), so instead of reconfiguring it we simply draw on top
    /// of it: `windowBackgroundColor` — the same opaque fill `PRPeekView`'s card
    /// already relies on to stop the list bleeding through — at the chosen alpha.
    ///
    /// At the default `0` nothing is drawn at all, so the stock panel is untouched.
    ///
    /// Rounded rather than a plain rect: the panel's corners are rounded by the
    /// window, and a square fill would either square them off or leave a hard edge
    /// in the corner. `panelCornerRadius` is deliberately a touch generous, so any
    /// mismatch with the window's own radius shows as a sliver of the original
    /// material in the corner rather than a fill spilling outside the window.
    @ViewBuilder
    private var panelBackdrop: some View {
        if PanelBackdrop.isOpaqueEnough(panelBackdropOpacity) {
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .opacity(panelBackdropOpacity)
                .ignoresSafeArea()
                // Purely decorative — it must never swallow a click meant for a row.
                .allowsHitTesting(false)
        }
    }

    /// The backdrop's alpha, clamped at the read site so a bad stored value is
    /// corrected in the view too, not only on load.
    private var panelBackdropOpacity: Double {
        PanelBackdrop.clamped(settings.panelBackgroundOpacity)
    }

    /// Corner radius for `panelBackdrop`, matched to the menu-bar panel's own
    /// corners. macOS 26 rounds them considerably more than 13–15 do, and the
    /// value is not exposed by AppKit, so it is picked off the running OS version
    /// rather than hard-coded to one era.
    private static var panelCornerRadius: CGFloat {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) ? 18 : 10
    }

    // MARK: - Derived data

    /// PRs belonging to the currently selected tab, filtered by scope, drafts, and
    /// the For-me Direct/Team sub-filter. This is the single source of truth for
    /// the visible list, the sections, and every count derived below. Delegates to
    /// `manager.currentViewPRs` — the SAME computation the menu-bar badge reads — so
    /// the list and the badge can never diverge; this view only adds the display
    /// sort. The browse deck's "Needs attention" group (`ActionGroup.needsAttention`)
    /// is the single "needs attention" concept; there is no separate top bucket.
    private var visiblePRs: [PRSnapshot] {
        manager.currentViewPRs.sorted(by: PRSnapshot.triageOrder)
    }

    /// The search matches for the current query, drawn from the whole tab
    /// (`searchBasePRs` — scope/draft independent) so a number/URL always resolves.
    /// The deck re-sorts these pinned-first; sorting here just gives a stable base.
    private var searchResults: [PRSnapshot] {
        let local = manager.searchBasePRs.filter { PRSearchFilter.matches($0, query: manager.searchQuery) }
        // Merge any PR fetched on demand for a pasted URL that no local PR covers.
        let fetched = manager.searchFetchedPRs.filter { PRSearchFilter.matches($0, query: manager.searchQuery) }
        var seen = Set<String>()
        return (local + fetched).filter { seen.insert($0.nodeId).inserted }
    }

    /// Whether a PR should count toward the tab labels. Honours both the draft
    /// toggle and the selected scope, so the tab label, the badge (when that tab
    /// is selected), and the visible list all agree. The For-me Direct/Team
    /// sub-filter is intentionally NOT applied here — it narrows the visible
    /// list/badge only, not the tab label.
    private func countsTowardTabs(_ pr: PRSnapshot) -> Bool {
        // Drafts.
        guard settings.showDrafts || pr.classifiedState != .draft else { return false }
        // Scope.
        guard let scope = scopeStore.selectedScope else { return true }
        switch scope {
        case .org(let o):  return pr.repoFullName.hasPrefix(o + "/")
        case .repo(let r): return pr.repoFullName == r
        }
    }

    /// Count for the For-me tab label (tab + scope + drafts).
    private var forMeCount: Int {
        manager.prs.filter { $0.tabs.contains(.forMe) && countsTowardTabs($0) }.count
    }

    /// Count for the Created tab label (tab + scope + drafts).
    private var createdCount: Int {
        manager.prs.filter { $0.tabs.contains(.created) && countsTowardTabs($0) }.count
    }

    /// Count for the Inbox tab label — active (non-muted) PRs only.
    private var inboxCount: Int {
        manager.inboxActivePRs.count
    }

    // MARK: - Height budget (content-sized, capped, crash-proof)
    //
    // A MenuBarExtra(.window) popover has NO external height constraint: it sizes
    // to its SwiftUI content and macOS clips (does NOT scroll) anything past the
    // screen. The OLD design nested TWO independently FIXED-height ScrollViews
    // (the browse list at `browseHeight` and the Needs-a-Human rows at
    // `maxExpandedHeight`) whose floors (150 + 140) could SUM to more than the
    // post-chrome budget. On expand the declared height jumped by ~300pt at once;
    // that oversized/animated resize reached NSHostingView mid-CATransaction and
    // aborted (invalidateSafeAreaInsets → setFrameSize: → uncaught NSException).
    // See the redesign below — a SINGLE scroll region, sized to MEASURED content
    // clamped to a finite cap, with every dimension guarded finite and >= 0.
    //
    // New invariant (defensive): chromeReserve + scrollRegionHeight <= cap <=
    // screen, where `scrollRegionHeight = clamp(measuredBody, floor, regionCap)`
    // and `regionCap = max(cap - chromeReserve, floor)`. `panelHeight` is now the
    // MAXIMUM total budget, not a fixed height: with few PRs the region shrinks to
    // the measured content, so the panel is short; it only grows to `regionCap`
    // (and scrolls) once content exceeds the budget.

    /// Guards any computed dimension before it reaches a `.frame`: never NaN, never
    /// infinite, never negative. Falls back to `fallback` for non-finite input.
    private func safe(_ value: CGFloat, fallback: CGFloat = 0) -> CGFloat {
        guard value.isFinite else { return max(0, fallback) }
        return max(0, value)
    }

    /// Floor for the scroll region — derived from the user's MIN panel height so the
    /// panel never shrinks below it with few PRs. The min is a TOTAL panel height, so
    /// convert to a scroll-region floor (minus fixed chrome), clamped not to exceed
    /// the max (`panelHeight`) and never below an absolute sliver guard (80pt).
    private var regionFloor: CGFloat {
        let effMin = min(CGFloat(settings.panelMinHeight), CGFloat(settings.panelHeight))
        return max(safe(effMin - chromeReserve, fallback: 120), 80)
    }

    /// The MAXIMUM total budget for the whole panel: the smaller of the user's
    /// preferred `panelHeight` and the real space below the menu bar (visibleFrame
    /// minus a small guard for the menu bar / popover arrow). Guaranteed finite and
    /// at least a 240pt floor so a tiny/garbage setting can never collapse the panel
    /// or feed a bad value downstream.
    private var cap: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height
        let screenBudget: CGFloat = (screen?.isFinite == true ? (screen! - 40) : 800)
        let requested = CGFloat(settings.panelHeight)
        let raw = min(requested.isFinite ? requested : 800, screenBudget)
        return max(safe(raw, fallback: 240), 240)
    }

    /// Fixed reserve for the always-present (non-scrolling) chrome. Summed from
    /// the real elements so it is not under-counted:
    ///   header ~44 + badge explainer ~22 + tab picker ~44 + scope/drafts row ~44 +
    ///   keyboard legend ~22 + footer ~48 + dividers/padding ~38
    ///   (+ For-me sub-filter ~36 only when the For-me tab is active).
    /// The old ~40pt reserve for the top "Needs a Human" header is gone — that
    /// header was removed when the browse list's "Needs attention" group became the
    /// single view. The rest of the crash-safe invariant is unchanged:
    /// chromeReserve + scrollRegionHeight <= cap <= screen, every term finite/>= 0.
    private var chromeReserve: CGFloat {
        let base: CGFloat = 44 + 22 + 44 + 44 + 22 + 48 + 38   // = 262
        let forMeFilter: CGFloat = settings.selectedTab == .forMe ? 36 : 0
        // The search field + its divider add fixed chrome while search is open.
        let searchBarReserve: CGFloat = manager.searchActive ? 40 : 0
        return base + forMeFilter + searchBarReserve
    }

    /// The maximum height the single scroll region may occupy: the cap minus the
    /// fixed chrome, floored so it is always usable. Finite and >= 0 by
    /// construction (cap and chromeReserve are both finite; `safe` guards the rest).
    private var regionCap: CGFloat {
        max(safe(cap - chromeReserve, fallback: regionFloor), regionFloor)
    }

    /// FINAL height for the single scroll region — the crux of the redesign.
    /// Sizes to the MEASURED natural height of its content (`measuredBodyHeight`)
    /// clamped between `regionFloor` and `regionCap`, so:
    ///   - few PRs  → short region (panel follows content, no huge empty area),
    ///   - many PRs → region caps at `regionCap` and scrolls within it.
    /// Every input is guarded finite/non-negative, so no NaN/∞/negative can ever
    /// reach the `.frame` on the ScrollView (the crash precondition).
    private var scrollRegionHeight: CGFloat {
        let measured = safe(measuredBodyHeight, fallback: regionFloor)
        // Before the first measurement lands, `measured` is 0 — fall back to the
        // cap so the region is usable on first render, then it settles to content.
        let effective = measured > 0 ? measured : regionCap
        let clamped = min(max(effective, regionFloor), regionCap)
        return safe(clamped, fallback: regionFloor)
    }

    /// Height for the peek card. Tracks the ACTUAL rendered panel height
    /// (`chromeReserve + scrollRegionHeight`) minus a small margin, so the card
    /// fills the available popover height rather than floating small — while never
    /// exceeding the panel bounds (which macOS would clip, not scroll). Floored so
    /// it stays usable on a short panel.
    private var peekHeight: CGFloat {
        let panel = chromeReserve + scrollRegionHeight
        return max(safe(panel - 48, fallback: 320), 320)
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
        Picker("Reviews", selection: Binding(
            get: { settings.selectedTab },
            set: { newTab in
                if newTab != settings.selectedTab {
                    settings.selectedTab = newTab
                    TelemetryService.shared.recordTriageInteraction("tab_switch")
                }
            }
        )) {
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
        case .inbox:   return inboxCount > 0   ? "Inbox (\(inboxCount))"      : tab.title
        }
    }

    // MARK: - For-me review sub-filter (Direct / Team)

    /// Compact segmented control shown only on the For-me tab. Filters the browse
    /// list by review-request source. Persisted in `settings.forMeReviewFilter`.
    private var forMeReviewFilterPicker: some View {
        Picker("Review source", selection: Binding(
            get: { settings.forMeReviewFilter },
            set: { newValue in
                settings.forMeReviewFilter = newValue
                TelemetryService.shared.recordTriageInteraction("for_me_filter_change")
            }
        )) {
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
                if !manager.availableScopes.isEmpty {
                    scopeChip(label: "All", scope: nil)
                    ForEach(manager.availableScopes, id: \.rawValue) { scope in
                        let count = manager.scopeCounts[scope] ?? 0
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
            TelemetryService.shared.recordTriageInteraction("toggle_drafts")
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
            if scopeStore.selectedScope != scope {
                scopeStore.selectedScope = scope
                TelemetryService.shared.recordTriageInteraction("scope_filter_change")
            }
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

    // MARK: - Search bar

    /// The in-app search field. Filters the current tab by PR number, GitHub PR
    /// URL, or free text (title / repo / author / branch) via `PRSearchFilter`.
    /// Return hands focus back to the deck (keeping the filter) so J/K + pin work;
    /// Esc / the ✕ / "Done" close search.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search by number, URL, or text…", text: Binding(
                get: { manager.searchQuery },
                set: { manager.searchQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($searchFieldFocused)
            .onSubmit {
                // Return: keep the filter, hand focus back to the deck for J/K + pin.
                searchFieldFocused = false
            }
            .onExitCommand {
                // Esc while the field is focused: close search entirely.
                manager.closeSearch()
            }
            if !manager.searchQuery.isEmpty {
                Button {
                    manager.searchQuery = ""
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            Button("Done") { manager.closeSearch() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Close search (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Starts intercepting the Down arrow while the search field is focused, handing
    /// focus to the results (the deck then has `selectedIndex == 0`, its first row)
    /// instead of letting the field editor move the cursor to line-end. Consuming the
    /// event (returning nil) is what suppresses that default. Only the Down key is
    /// touched; every other key — typing, ←/→ cursor, Up, Return, Esc — passes through.
    private func installSearchDownMonitor() {
        guard searchDownKeyMonitor == nil else { return }
        searchDownKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 125 else { return event }   // 125 = Down arrow
            // Defer the focus change one runloop tick — mutating focus state inside
            // event handling is unsafe — but consume the key now so the cursor stays put.
            DispatchQueue.main.async { searchFieldFocused = false }
            return nil
        }
    }

    /// Removes the Down-arrow monitor (field lost focus, search closed, or view gone).
    private func removeSearchDownMonitor() {
        if let monitor = searchDownKeyMonitor {
            NSEvent.removeMonitor(monitor)
            searchDownKeyMonitor = nil
        }
    }

    // MARK: - Scope cycling

    private func cycleScopeForward() {
        let all: [PRScope?] = [nil] + manager.availableScopes
        let current = scopeStore.selectedScope
        if let idx = all.firstIndex(where: { $0 == current }) {
            let next = all[(idx + 1) % all.count]
            scopeStore.selectedScope = next
        } else {
            scopeStore.selectedScope = nil
        }
        TelemetryService.shared.recordTriageInteraction("scope_filter_change")
    }

    private func cycleScopeBackward() {
        let all: [PRScope?] = [nil] + manager.availableScopes
        let current = scopeStore.selectedScope
        if let idx = all.firstIndex(where: { $0 == current }) {
            let prev = all[(idx - 1 + all.count) % all.count]
            scopeStore.selectedScope = prev
        } else {
            scopeStore.selectedScope = nil
        }
        TelemetryService.shared.recordTriageInteraction("scope_filter_change")
    }

    // MARK: - Scrollable body (SINGLE region: the actionability-grouped browse deck)

    /// The one and only scroll region: the tabbed browse deck, grouped by
    /// actionability (Needs attention → Ready to merge → Waiting → Draft → Merged →
    /// Closed). Its height is the MEASURED natural height of that content clamped to
    /// `regionCap`, so the panel is short with few PRs and scrolls only when content
    /// overflows. The separate top "Needs a Human" bucket was removed — the
    /// list's "Needs attention" group is the single "needs attention" view.
    ///
    /// A `GeometryReader` background measures the natural content height and reports
    /// it via `BodyHeightKey`; `onPreferenceChange` stores it in `measuredBodyHeight`.
    /// The `.frame(height:)` uses `scrollRegionHeight`, which is guarded finite and
    /// clamped — no NaN/∞/negative can reach the hosting view.
    @ViewBuilder
    private var scrollableBody: some View {
        // While searching, always render the deck (it shows its own "No matching PRs"
        // state) so a valid match isn't hidden by the tab-level empty short-circuit.
        let isEmpty = !manager.hasToken || (!manager.searchActive && (
            settings.selectedTab == .inbox
                ? manager.inboxActivePRs.isEmpty && manager.inboxMutedPRs.isEmpty
                : manager.prs.isEmpty
        ))
        if isEmpty {
            emptyState
        } else {
            ScrollView {
                bodyContent
                    .background(bodyHeightReader)
            }
            .frame(height: scrollRegionHeight)
        }
    }

    /// The measured content: the actionability-grouped browse deck.
    ///
    /// A plain (NON-lazy) `VStack` so the `GeometryReader` background measures the
    /// FULL natural height of the content — including a freshly expanded section's
    /// rows. With a `LazyVStack` the added rows sit below the current small frame and
    /// are never realized/measured, so the panel would not grow on expand. Eager
    /// layout means expanding a section raises `measuredBodyHeight` →
    /// `scrollRegionHeight` grows (up to `regionCap`) → the panel grows, and once
    /// content exceeds the cap the single OUTER `ScrollView` scrolls.
    @ViewBuilder
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The keyboard-navigable triage deck, grouped into collapsible
            // actionability sections, scoped to the selected tab. Its
            // "Needs attention" group (`ActionGroup.needsAttention`) is the single
            // "needs attention" concept — there is no separate top bucket.
            TriageDeckView(
                prs: manager.searchActive ? searchResults : visiblePRs,
                mutedPRs: (settings.selectedTab == .inbox && !manager.searchActive) ? manager.inboxMutedPRs : [],
                inboxMode: settings.selectedTab == .inbox && !manager.searchActive,
                searchMode: manager.searchActive,
                searchFieldFocused: searchFieldFocused,
                manager: manager,
                settings: settings
            )
        }
    }

    /// Transparent background that measures the natural height of the body content
    /// and publishes it via `BodyHeightKey`. Guarded to a finite, non-negative
    /// value before it is ever read into a frame.
    private var bodyHeightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: BodyHeightKey.self,
                value: safe(proxy.size.height, fallback: 0)
            )
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
        case .inbox:   return "Inbox clear"
        }
    }

    // MARK: - Keyboard legend

    /// Always-visible discoverability strip for the deck's keyboard verbs and the
    /// row context menu — replaces the ⌘K command palette as the "what can I do
    /// here?" affordance.
    private var keyboardLegend: some View {
        // Built from the LIVE bindings so the glyphs always match Settings →
        // Keyboard (never stale), and wrapped over up to two lines so every verb
        // stays readable instead of truncating to one clipped line.
        let b = settings.shortcutBindings
        func g(_ s: InAppShortcut) -> String { MainlineSettings.glyph(for: b.binding(for: s)) }
        var parts: [String] = [
            "\(g(.navigateDown))/\(g(.navigateUp)) move",
            "\(g(.peek)) peek",
            "↵ open",
            "\(g(.search)) find",
            "\(g(.togglePin)) pin",
            "\(g(.openPreview)) preview",
            "\(g(.merge)) merge",
            "\(g(.snooze)) later",
        ]
        if settings.selectedTab == .inbox {
            parts.append("\(g(.toggleMute)) mute")
        }
        parts.append("\(g(.undo)) undo")
        parts.append("right-click ▸ all")

        return HStack(spacing: 0) {
            Text(parts.joined(separator: "   ·   "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

        // MARK: - Footer (AC-21: 44pt hit targets, Quit separated)

    private var footer: some View {
        HStack(spacing: 0) {
            // AC-20: Refresh shows spinner + disabled during refresh
            Button {
                TelemetryService.shared.recordTriageInteraction("refresh")
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

// MARK: - Body height measurement

/// Carries the measured natural height of the scrollable body up to `MenuBarView`
/// so the panel can size its single scroll region to content, clamped to the cap.
/// The reduce keeps the largest reported height (the fullest layout pass).
private struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        // Defensive: never let a non-finite/negative measurement propagate.
        let safeNext = next.isFinite ? max(0, next) : 0
        value = max(value, safeNext)
    }
}
