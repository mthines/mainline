import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var manager: PRManager
    @ObservedObject private var settings: MainlineSettings

    @State private var patDraft: String = ""
    @State private var patSaved: Bool = false
    @State private var importError: String? = nil
    @State private var isImporting: Bool = false

    init(manager: PRManager) {
        self.manager  = manager
        self.settings = manager.settings
    }

    var body: some View {
        Form {
            // MARK: - GitHub Token
            Section("GitHub Token") {
                SecureField("Personal Access Token", text: $patDraft)
                    .textFieldStyle(.roundedBorder)

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
            if let token = await KeychainHelper.loadToken() {
                await MainActor.run {
                    // Show a masked placeholder — don't expose the real token in a text field
                    patDraft = String(repeating: "•", count: min(token.count, 20))
                }
            }
        }
    }

    private func saveToken() {
        let token = patDraft
        Task {
            do {
                try KeychainHelper.saveToken(token)
                await MainActor.run {
                    patSaved = true
                    importError = nil
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
                    patDraft   = String(repeating: "•", count: min(token.count, 20))
                    patSaved   = true
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
                // Find gh on PATH
                let ghPath = ["gh", "/usr/local/bin/gh", "/opt/homebrew/bin/gh"]
                    .first { FileManager.default.isExecutableFile(atPath: $0.hasPrefix("/") ? $0 : "/usr/bin/env") }
                    ?? "gh"

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments     = [ghPath, "auth", "token"]

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
