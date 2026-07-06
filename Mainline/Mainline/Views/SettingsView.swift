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
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420, height: 480)
        .onAppear {
            loadToken()
        }
    }

    // MARK: - Actions

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
