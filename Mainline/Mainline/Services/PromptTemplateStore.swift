import AppKit
import Foundation

// MARK: - Terminal choice

/// Which terminal app CLI harnesses open in. `.auto` hands the generated `.command`
/// script to macOS, which uses whatever app the user has set for that file type.
enum PromptTerminal: String, CaseIterable, Identifiable {
    case auto
    case terminal
    case iterm
    case ghostty
    case warp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:     return "Automatic (system default)"
        case .terminal: return "Terminal"
        case .iterm:    return "iTerm"
        case .ghostty:  return "Ghostty"
        case .warp:     return "Warp"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .auto:     return nil
        case .terminal: return "com.apple.Terminal"
        case .iterm:    return "com.googlecode.iterm2"
        case .ghostty:  return "com.mitchellh.ghostty"
        case .warp:     return "dev.warp.Warp-Stable"
        }
    }

    var appURL: URL? {
        bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    var isInstalled: Bool { self == .auto || appURL != nil }
}

// MARK: - Store

/// Owns `~/.config/mainline/`: `config.json` (harnesses, repo paths, checkout step)
/// and `prompts/*.md` (one template per file). The files are the single source of
/// truth — Settings edits them through `save`/`delete`, and edits made in an editor
/// are picked up by a cheap 2-second signature check.
@MainActor
final class PromptTemplateStore: ObservableObject {
    @Published private(set) var templates: [PromptTemplate] = []
    @Published private(set) var config: PromptConfig = .default
    /// Why `config.json` could not be used (the last good config stays active).
    @Published private(set) var configError: String?
    /// Bumped whenever the loaded templates or config change. Folded into the deck's
    /// memoized row key so a row's right-click "Run Prompt" menu never goes stale.
    @Published private(set) var revision = 0

    let directory: URL
    var promptsDirectory: URL { directory.appendingPathComponent("prompts", isDirectory: true) }
    var configURL: URL { directory.appendingPathComponent("config.json") }

    private var watchTask: Task<Void, Never>?
    private var lastSignature = ""

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mainline", isDirectory: true)) {
        self.directory = directory
    }

    deinit { watchTask?.cancel() }

    /// Seeds missing files, loads, and starts watching. Idempotent.
    func start() {
        guard watchTask == nil else { return }
        seedIfNeeded()
        reload()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                self.reloadIfChanged()
            }
        }
    }

    // MARK: Seeding

    /// Writes `config.json` when absent, and the starter templates + README only when
    /// the prompts folder doesn't exist — so deleting a starter sticks.
    private func seedIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configURL.path) { writeConfig(.default) }
        if !fm.fileExists(atPath: promptsDirectory.path) {
            try? fm.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)
            for t in PromptStarters.templates {
                try? PromptStarters.fileContents(for: t).write(to: promptsDirectory.appendingPathComponent(t.fileName),
                                                               atomically: true, encoding: .utf8)
            }
            try? PromptStarters.readme.write(to: promptsDirectory.appendingPathComponent("README.txt"),
                                             atomically: true, encoding: .utf8)
        }
    }

    private func writeConfig(_ config: PromptConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(config) { try? data.write(to: configURL, options: .atomic) }
    }

    // MARK: Loading

    private func signature() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        let urls = [configURL] + ((try? fm.contentsOfDirectory(at: promptsDirectory, includingPropertiesForKeys: nil)) ?? [])
        for url in urls.sorted(by: { $0.path < $1.path }) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            parts.append("\(url.lastPathComponent)@\(date?.timeIntervalSince1970 ?? 0)")
        }
        return parts.joined(separator: "|")
    }

    private func reloadIfChanged() {
        if signature() != lastSignature { reload() }
    }

    func reload() {
        lastSignature = signature()

        if let data = try? Data(contentsOf: configURL) {
            do {
                let decoded = try JSONDecoder().decode(PromptConfig.self, from: data)
                if decoded != config { config = decoded; revision &+= 1 }
                configError = nil
            } catch {
                configError = "config.json: \(error.localizedDescription)"
            }
        }

        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: promptsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let loaded = files.compactMap { url -> PromptTemplate? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return PromptEngine.parse(fileName: url.lastPathComponent, text: text)
        }
        if loaded != templates { templates = loaded; revision &+= 1 }
    }

    // MARK: Editing (Settings)

    /// A new, unsaved template pointing at the first available harness.
    func newTemplate() -> PromptTemplate {
        let name = "New template"
        return PromptTemplate(
            fileName: PromptEngine.fileName(forName: name, existing: Set(templates.map(\.fileName))),
            name: name,
            harness: config.enabledHarnesses.first?.key ?? "claude",
            checkout: false,
            body: "Review {{pr.url}}"
        )
    }

    func save(_ template: PromptTemplate) {
        try? FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)
        try? PromptEngine.serialize(template).write(
            to: promptsDirectory.appendingPathComponent(template.fileName), atomically: true, encoding: .utf8)
        reload()
    }

    func delete(_ template: PromptTemplate) {
        try? FileManager.default.removeItem(at: promptsDirectory.appendingPathComponent(template.fileName))
        reload()
    }

    /// Enables/disables a harness by rewriting `config.json`. Refuses while the file
    /// can't be parsed — rewriting then would overwrite the user's hand edits.
    func setHarnessEnabled(_ key: String, _ on: Bool) {
        patchConfigFile { raw, _ in
            var harnesses = raw["harnesses"] as? [String: Any] ?? [:]
            guard var harness = harnesses[key] as? [String: Any] else { return false }
            if on { harness.removeValue(forKey: "enabled") } else { harness["enabled"] = false }
            harnesses[key] = harness
            raw["harnesses"] = harnesses
            return true
        }
    }

    /// Moves a harness up (`-1`) or down (`+1`) in priority.
    func moveHarness(_ key: String, by delta: Int) {
        patchConfigFile { raw, current in
            let moved = current.moving(key, by: delta)
            guard moved.order != current.order else { return false }
            raw["order"] = moved.order
            return true
        }
    }

    /// Changes ONLY the fields a Settings control owns, in the file's own JSON: keys
    /// this app doesn't know (notes, per-harness extras) survive, and the file is re-read
    /// first so a hand edit saved a moment ago isn't overwritten from a stale copy.
    /// Refuses while the file can't be parsed. `mutate` returns false for "nothing to do".
    private func patchConfigFile(_ mutate: (inout [String: Any], PromptConfig) -> Bool) {
        reloadIfChanged()
        guard configError == nil,
              let data = try? Data(contentsOf: configURL),
              var raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // A file that omits a section (lenient decode) still needs it written out in full
        // before one of its entries can be edited.
        if raw["harnesses"] == nil,
           let encoded = try? JSONEncoder().encode(config),
           let obj = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
            raw["harnesses"] = obj["harnesses"]
        }
        guard mutate(&raw, config),
              let out = try? JSONSerialization.data(
                withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? out.write(to: configURL, options: .atomic)
        reload()
    }

    func revealPromptsFolder() {
        try? FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(promptsDirectory)
    }

    func openConfig() {
        seedIfNeeded()
        NSWorkspace.shared.open(configURL)
    }
}

// MARK: - Launcher

enum PromptLaunchError: Error, LocalizedError {
    case pathMissing(String)
    case couldNotOpen(String)

    var errorDescription: String? {
        switch self {
        case .pathMissing(let p): return "Local path for this repo doesn't exist: \(p)"
        case .couldNotOpen(let what): return "Couldn't open \(what)."
        }
    }
}

/// Impure shell: writes the script + prompt to a temp dir and hands it to the
/// terminal (CLI harnesses) or the browser (web harnesses).
@MainActor
enum PromptLauncher {
    /// Runs `prompt` on `pr` with the harness. Returns a one-line summary for a toast.
    static func run(prompt: String, harnessKey: String, checkout: Bool, pr: PRSnapshot,
                    context: PromptContext? = nil, config: PromptConfig,
                    terminal: PromptTerminal) throws -> String {
        let context = context ?? PromptContext(pr: pr)
        let harness = config.harnesses[harnessKey]
        let label = harness?.label ?? harnessKey
        let localPath = config.localPath(forRepo: pr.repoFullName)

        if let localPath, harness?.isWeb == false {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir), isDir.boolValue else {
                throw PromptLaunchError.pathMissing(localPath)
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mainline-prompts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneOldFiles(in: dir)
        let stem = UUID().uuidString
        let promptFile = dir.appendingPathComponent("\(stem).txt")

        let launch = try PromptEngine.launch(
            prompt: prompt, harnessKey: harnessKey, config: config, context: context,
            checkout: checkout, workingDirectory: localPath, promptFile: promptFile.path)

        switch launch {
        case .web(let url):
            guard NSWorkspace.shared.open(url) else { throw PromptLaunchError.couldNotOpen(label) }
            return "Opened \(label)"

        case .terminal(let script, let text):
            try text.write(to: promptFile, atomically: true, encoding: .utf8)
            let scriptURL = dir.appendingPathComponent("\(stem).command")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            try open(scriptURL, in: terminal)

            var summary = "Started \(label)"
            if let localPath { summary += " in \((localPath as NSString).abbreviatingWithTildeInPath)" }
            else if checkout { summary += " in ~ (no path for \(pr.repoFullName) in config.json — checkout skipped)" }
            return summary
        }
    }

    private static func open(_ script: URL, in terminal: PromptTerminal) throws {
        switch terminal {
        case .auto:
            guard NSWorkspace.shared.open(script) else { throw PromptLaunchError.couldNotOpen("a terminal") }
        case .ghostty:
            // Ghostty doesn't take `.command` files as documents; `-e` runs the script.
            guard let app = terminal.appURL else { throw PromptLaunchError.couldNotOpen(terminal.displayName) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", app.path, "--args", "-e", script.path]
            try process.run()
        case .terminal, .iterm, .warp:
            guard let app = terminal.appURL else { throw PromptLaunchError.couldNotOpen(terminal.displayName) }
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Scripts and prompt files are single-use; drop anything older than a day.
    private static func pruneOldFiles(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-86_400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
