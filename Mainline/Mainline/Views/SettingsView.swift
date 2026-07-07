import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject private var settings: MainlineSettings

    @State private var patDraft: String = ""
    @State private var patSaved: Bool = false
    @State private var importError: String? = nil
    @State private var isImporting: Bool = false
    @State private var hasStoredToken: Bool = false
    @State private var panelHeightDraft: Int = 560

    // Panel-height bounds. The setting may store a large number; the render path
    // in MenuBarView clamps it to the usable screen height, so a big value just
    // makes the panel as tall as the display allows.
    static let panelHeightMin = 300
    static let panelHeightMax = 2000

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
        Form {
            // MARK: - GitHub Token
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

            // MARK: - Poll Interval
            Section("Polling") {
                Stepper(
                    "Poll interval: \(settings.pollIntervalSeconds)s",
                    value: $settings.pollIntervalSeconds,
                    in: 30...3600,
                    step: 30
                )
            }

            // MARK: - Search Queries
            Section("Search Queries") {
                TextField("Author query", text: $settings.searchQueryAuthor)
                    .textFieldStyle(.roundedBorder)
                TextField("Reviewer query", text: $settings.searchQueryReviewer)
                    .textFieldStyle(.roundedBorder)
            }

            // MARK: - Notification Toggles
            Section("Notifications") {
                Toggle("New PR", isOn: $settings.notifyNewPR)
                Toggle("Ready for Review", isOn: $settings.notifyReadyForReview)
                Toggle("CI Status Changed", isOn: $settings.notifyCIChange)
                Toggle("New Review / Comment", isOn: $settings.notifyReviewComment)
            }

            // MARK: - Triage (Layer B / D)
            Section("Write Actions") {
                Toggle("Enable write actions (Approve, Merge, Request Changes)", isOn: $settings.writeActionsEnabled)
                if settings.writeActionsEnabled {
                    Toggle("Enable autopilot auto-approve (advanced)", isOn: $settings.autopilotEnabled)
                    if settings.autopilotEnabled {
                        Label("Auto-approve fires when author is autopilot tier, CI green, and < 50 LOC changed.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: - Triage Focus
            Section("Triage") {
                Toggle("Show draft PRs", isOn: $settings.showDrafts)
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

                Toggle("Route merge conflicts to \"Needs a Human\"", isOn: $settings.includeConflictsInNeedsHuman)
                Label("When off, the Needs-a-Human bucket focuses on failing CI; conflicts still show as a tag on rows but don't route PRs into the bucket.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: - Attention Policy
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

            // MARK: - Menu Bar (Bug 2 / 5)
            Section("Menu Bar") {
                Picker("Badge counts", selection: $settings.menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Follow selected scope", isOn: $settings.menuBarScopeFollowsSelection)

                Label("The badge counts the chosen metric" +
                      (settings.menuBarScopeFollowsSelection ? ", narrowed to the scope you've selected in the panel." : " across all repositories."),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: - Panel
            Section("Panel") {
                HStack {
                    Text("Panel height (pt)")
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
                Label("Capped to the display height — very large values make the panel as tall as the screen allows.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420, height: 560)
        .onAppear {
            loadToken()
            panelHeightDraft = settings.panelHeight
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
