import SwiftUI
import AppKit

// MARK: - Settings categories

/// The sidebar categories for the settings window. Raw value drives the
/// SF Symbol; `title` is the human-readable label shown in the sidebar and as
/// the detail-pane heading.
private enum SettingsCategory: String, CaseIterable, Identifiable {
    case github
    case notifications
    case menuBar
    case appearance
    case keyboard
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github:        return "GitHub"
        case .notifications: return "Notifications"
        case .menuBar:       return "Menu Bar"
        case .appearance:    return "Appearance"
        case .keyboard:      return "Keyboard"
        case .privacy:       return "Privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .github:        return "key.fill"
        case .notifications: return "bell.fill"
        case .menuBar:       return "menubar.rectangle"
        case .appearance:    return "slider.horizontal.3"
        case .keyboard:      return "keyboard"
        case .privacy:       return "hand.raised.fill"
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject private var settings: MainlineSettings

    @State private var selection: SettingsCategory? = .github

    @State private var patDraft: String = ""
    @State private var patSaved: Bool = false
    @State private var importError: String? = nil
    @State private var isImporting: Bool = false
    @State private var hasStoredToken: Bool = false
    @State private var panelHeightDraft: Int = 560
    @State private var panelMinHeightDraft: Int = 240
    @State private var showingTelemetryDetails: Bool = false

    // Panel-height bounds. The setting may store a large number; the render path
    // in MenuBarView clamps it to the usable screen height, so a big value just
    // makes the panel as tall as the display allows.
    static let panelHeightMin = 300
    static let panelHeightMax = 2000
    static let panelMinHeightMin = 200

    static let panelHeightFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.allowsFloats = false
        f.minimum = NSNumber(value: panelHeightMin)
        f.maximum = NSNumber(value: panelHeightMax)
        return f
    }()

    init(manager: PRManager) {
        self.manager  = manager
        self.settings = manager.settings
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailPane(for: selection ?? .github)
                .navigationSplitViewColumnWidth(min: 440, ideal: 520)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            loadToken()
            panelHeightDraft = settings.panelHeight
            panelMinHeightDraft = settings.panelMinHeight
        }
    }

    // MARK: - Detail pane routing

    @ViewBuilder
    private func detailPane(for category: SettingsCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(category.title)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            Form {
                switch category {
                case .github:        githubSection
                case .notifications: notificationsSection
                case .menuBar:       menuBarSection
                case .appearance:    appearanceSection
                case .keyboard:      keyboardSection
                case .privacy:       privacySection
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - GitHub

    @ViewBuilder
    private var githubSection: some View {
        Section("GitHub Token") {
            SecureField(
                hasStoredToken ? "A token is stored — paste a new one to replace" : "Personal Access Token",
                text: $patDraft
            )
            .textFieldStyle(.roundedBorder)

            if hasStoredToken && !patSaved {
                Label("A token is stored", systemImage: "key.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            HStack {
                Button("Save Token") {
                    saveToken()
                }
                .disabled(patDraft.isEmpty)

                Button("Import from gh") {
                    importFromGH()
                }
                .disabled(isImporting)

                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if patSaved {
                Label("Token saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section("Search Queries") {
            TextField("Author query", text: $settings.searchQueryAuthor)
                .textFieldStyle(.roundedBorder)
            TextField("Reviewer query", text: $settings.searchQueryReviewer)
                .textFieldStyle(.roundedBorder)
        }

        Section("Polling") {
            Stepper(
                "Poll interval: \(settings.pollIntervalSeconds)s",
                value: $settings.pollIntervalSeconds,
                in: 30...3600,
                step: 30
            )
        }

        Section("Write Actions") {
            Toggle("Enable write actions (Approve, Merge, Request Changes)", isOn: $settings.writeActionsEnabled)
            if settings.writeActionsEnabled {
                Picker("Merge method", selection: $settings.mergeMethodPreference) {
                    ForEach(MergeMethodPreference.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                Label("Auto picks the repo's allowed method (squash → rebase → merge commit).", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Opening PRs") {
            Picker("Open PRs in", selection: $settings.prOpenTarget) {
                ForEach(PROpenTarget.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }
            if settings.prOpenTarget == .linear {
                TextField("Linear workspace", text: $settings.linearWorkspaceSlug, prompt: Text("your-workspace"))
                    .textFieldStyle(.roundedBorder)
                Label("The workspace slug from your Linear URL (linear.app/<workspace>). Clicking a PR opens its linked Linear issue in the desktop app, derived from the branch name (e.g. eng-1234). Falls back to GitHub when no issue id is found. The peek card's Safari button always opens GitHub.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Preview Deployments") {
            Toggle("Detect Vercel preview deployments", isOn: $settings.vercelPreviewEnabled)
            if settings.vercelPreviewEnabled {
                TextField("Preview domains", text: previewDomainsBinding, prompt: Text("dash0-preview.com, vercel.app"))
                    .textFieldStyle(.roundedBorder)
                Label("Comma-separated host suffixes to match in the Vercel bot comment, most-preferred first. A matching PR shows a “Preview” badge; press P to open it.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Bridges the `[String]` preview-domains setting to a single comma-separated
    /// text field. Splitting on commas and trimming keeps the stored list clean
    /// regardless of spacing.
    private var previewDomainsBinding: Binding<String> {
        Binding(
            get: { settings.vercelPreviewDomains.joined(separator: ", ") },
            set: { newValue in
                settings.vercelPreviewDomains = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        Section("Attention Policy") {
            Text("Control how interrupting each event is.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(PREvent.allCases, id: \.rawValue) { event in
                HStack {
                    Text(event.displayName)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.level(for: event) },
                        set: { newLevel in
                            var policy = settings.attentionPolicy
                            policy[event.rawValue] = newLevel.rawValue
                            settings.attentionPolicy = policy
                        }
                    )) {
                        Text("Notify").tag(AttentionLevel.notify)
                        Text("Quiet").tag(AttentionLevel.quiet)
                        Text("Off").tag(AttentionLevel.off)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
        }

        Section("Comments") {
            Toggle("Only notify for comments from people (ignore bots)",
                   isOn: $settings.notifyOnlyHumanComments)
            Label("Skips the \"New review or comment\" banner when the latest comment or review is from a bot or app (CodeRabbit, Vercel, dependabot, Claude review bots, …). Unread and badge counts are unaffected.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Menu Bar

    @ViewBuilder
    private var menuBarSection: some View {
        Section("Badge") {
            Picker("Badge counts", selection: $settings.menuBarMetric) {
                ForEach(MenuBarMetric.allCases) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .pickerStyle(.menu)

            Toggle("Follow current view (tab, scope & drafts)", isOn: $settings.menuBarScopeFollowsSelection)

            Label("The badge counts the chosen metric" +
                  (settings.menuBarScopeFollowsSelection ? " over exactly what the panel shows — the selected tab, scope, and drafts filter." : " across all repositories, ignoring the selected tab, scope, and drafts."),
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Global Shortcut") {
            Toggle("Open Mainline with a global shortcut", isOn: $settings.globalShortcutEnabled)

            HStack {
                Text("Shortcut")
                Spacer()
                ShortcutRecorder(settings: settings)
                    .disabled(!settings.globalShortcutEnabled)
                Button("Reset to default (\(MainlineSettings.defaultGlobalShortcutDisplayString))") {
                    settings.resetGlobalShortcutToDefault()
                }
                .disabled(!settings.globalShortcutEnabled)
            }

            Label("Press this key combination from any app to open the Mainline popover. Requires at least one modifier key.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Panel") {
            HStack {
                Text("Min panel height (pt)")
                Spacer()
                TextField("", value: $panelMinHeightDraft, formatter: Self.panelHeightFormatter)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onSubmit { commitPanelMinHeight() }
                Stepper("", value: $panelMinHeightDraft, in: Self.panelMinHeightMin...Self.panelHeightMax, step: 20)
                    .labelsHidden()
                    .onChange(of: panelMinHeightDraft) { _ in commitPanelMinHeight() }
            }
            Label("The MINIMUM height — the panel never shrinks below this even with few PRs. Clamped to the max below.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Max panel height (pt)")
                Spacer()
                TextField("", value: $panelHeightDraft, formatter: Self.panelHeightFormatter)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onSubmit { commitPanelHeight() }
                Stepper("", value: $panelHeightDraft, in: Self.panelHeightMin...Self.panelHeightMax, step: 20)
                    .labelsHidden()
                    .onChange(of: panelHeightDraft) { _ in commitPanelHeight() }
            }
            Label("The MAXIMUM height — the panel sizes to its content and only grows up to this (scrolling beyond it). Capped to the display height, so very large values just let it fill the screen.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Compact rows", isOn: $settings.compactRows)
            Label("Single-line titles, tighter spacing — fit more PRs.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Triage") {
            Picker("Default postpone duration", selection: $settings.defaultSnoozeDuration) {
                ForEach(SnoozeDuration.allCases) { duration in
                    Text(duration.title).tag(duration)
                }
            }
            Label("Applied when you press S to postpone a PR. The clock button and row menu still offer every duration.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Drafts") {
            Toggle("Show draft PRs", isOn: Binding(
                get: { settings.showDrafts },
                set: { newValue in
                    settings.showDrafts = newValue
                    TelemetryService.shared.recordTriageInteraction("drafts_toggle")
                }
            ))
            Label("When off, drafts are hidden from the list, sections, counts, and the Needs-a-Human bucket. Toggle in the panel with the Drafts chip or ⌘D.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Group drafts in their own section", isOn: $settings.splitDrafts)
            Label("When off, shown drafts are mixed into their real state group (Open, Approved, …) and marked with a Draft badge.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Keyboard

    @ViewBuilder
    private var keyboardSection: some View {
        KeyboardShortcutsView(settings: settings)
    }

    // MARK: - Privacy

    @ViewBuilder
    private var privacySection: some View {
        TelemetryOptInBanner()
            .padding(.horizontal, 16)
            .padding(.top, 8)

        Section("Telemetry") {
            Toggle("Share anonymous usage data", isOn: $settings.telemetryEnabled)
            Label("Opt-in. Poll results, error categories, triage interaction counts — never PR titles, repo names, or tokens.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Learn more about what is collected") {
                showingTelemetryDetails = true
            }
            .buttonStyle(.link)
        }
        .sheet(isPresented: $showingTelemetryDetails) {
            TelemetryDetailsSheet()
        }
    }

    // MARK: - Actions

    /// Clamp the typed/stepped draft to the allowed range and persist it. Keeps
    /// the setting from going below ~300 or above the max; MenuBarView further
    /// bounds it to the usable screen height at render time.
    private func commitPanelHeight() {
        let clamped = min(max(panelHeightDraft, Self.panelHeightMin), Self.panelHeightMax)
        if clamped != panelHeightDraft {
            panelHeightDraft = clamped
        }
        if settings.panelHeight != clamped {
            settings.panelHeight = clamped
        }
    }

    /// Clamp the min-height draft to its range and to the current max, then persist.
    /// MenuBarView also clamps min <= max defensively at render time.
    private func commitPanelMinHeight() {
        let ceiling = min(Self.panelHeightMax, panelHeightDraft)
        let clamped = min(max(panelMinHeightDraft, Self.panelMinHeightMin), ceiling)
        if clamped != panelMinHeightDraft {
            panelMinHeightDraft = clamped
        }
        if settings.panelMinHeight != clamped {
            settings.panelMinHeight = clamped
        }
    }

    private func loadToken() {
        Task {
            let token = await KeychainHelper.loadToken()
            await MainActor.run {
                // Never place the real token (or a masked stand-in) into the editable
                // field — doing so risks saving the placeholder back over the token.
                // Track presence separately and keep the field empty.
                hasStoredToken = !(token ?? "").isEmpty
                patDraft = ""
            }
        }
    }

    private func saveToken() {
        let token = patDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against saving an empty value or the masked bullet placeholder.
        guard !token.isEmpty, !token.contains("•") else {
            importError = "Enter a token before saving."
            return
        }
        Task {
            do {
                try KeychainHelper.saveToken(token)
                await MainActor.run {
                    patSaved = true
                    importError = nil
                    hasStoredToken = true
                    patDraft = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        patSaved = false
                    }
                }
                await manager.fetchUsername(token: token)
                TelemetryService.shared.recordTokenImport(method: "paste")
                await manager.restart()
            } catch {
                await MainActor.run {
                    importError = "Failed to save token: \(error.localizedDescription)"
                }
            }
        }
    }

    private func importFromGH() {
        importError = nil
        isImporting = true

        Task {
            do {
                let token = try await runGHAuthToken()
                try KeychainHelper.saveToken(token)
                await MainActor.run {
                    patDraft    = ""
                    hasStoredToken = true
                    patSaved    = true
                    isImporting = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        patSaved = false
                    }
                }
                await manager.fetchUsername(token: token)
                TelemetryService.shared.recordTokenImport(method: "gh")
                await manager.restart()
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    // MARK: - gh auth token subprocess

    private func runGHAuthToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                // GUI apps launched from Finder/Dock inherit a minimal PATH that
                // excludes Homebrew, so `env gh` can't find it. Try known absolute
                // locations first, then fall back to a login shell that resolves the
                // user's real PATH.
                let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
                let ghAbsolute = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

                let process = Process()
                if let ghAbsolute {
                    process.executableURL = URL(fileURLWithPath: ghAbsolute)
                    process.arguments     = ["auth", "token"]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments     = ["-lc", "gh auth token"]
                }

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError  = stderr

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(throwing: ImportError.ghNotFound)
                    return
                }

                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let token = output.trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus != 0 || token.isEmpty {
                    let msg = errOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ImportError.ghFailed(msg.isEmpty ? "Exit code \(process.terminationStatus)" : msg))
                } else {
                    continuation.resume(returning: token)
                }
            }
        }
    }

    private enum ImportError: Error, LocalizedError {
        case ghNotFound
        case ghFailed(String)

        var errorDescription: String? {
            switch self {
            case .ghNotFound:
                return "gh not found — install GitHub CLI from cli.github.com"
            case .ghFailed(let msg):
                return "gh auth token failed: \(msg)"
            }
        }
    }
}

// MARK: - ShortcutRecorder

/// A button that displays the current global shortcut and, when clicked, enters
/// "recording" mode to capture the next key-down (macOS 13-safe via a local
/// `NSEvent` monitor). Requires at least one modifier; Escape cancels.
private struct ShortcutRecorder: View {
    @ObservedObject var settings: MainlineSettings
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(isRecording ? "Press keys…" : settings.globalShortcutDisplayString)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 90)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .help(isRecording ? "Press a key combination, or Escape to cancel" : "Click to record a new shortcut")
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        // Capture the NEXT key-down locally. Returning nil swallows the event so
        // it doesn't reach other controls while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Escape cancels recording without changing the shortcut.
        if event.keyCode == 0x35 { // Escape
            stopRecording()
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require at least one modifier so the combo is a safe global hotkey.
        guard !mods.isEmpty else { return }

        settings.globalShortcutKeyCode   = Int(event.keyCode)
        settings.globalShortcutModifiers = mods.rawValue
        stopRecording()
    }
}
