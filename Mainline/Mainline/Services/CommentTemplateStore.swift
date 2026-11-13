import AppKit
import Foundation

/// Owns `~/.config/mainline/comments/` — one `.md` file per canned PR comment (see
/// `CommentEngine`). Like `PromptTemplateStore`, the files are the single source of truth:
/// Settings edits them through `save`/`delete`, and edits made in an editor are picked up
/// by a cheap 2-second signature check.
@MainActor
final class CommentTemplateStore: ObservableObject {
    @Published private(set) var templates: [CommentTemplate] = []
    /// Bumped whenever the loaded templates change. Folded into the deck's memoized row
    /// key so a row's right-click "Comment" menu never goes stale.
    @Published private(set) var revision = 0

    let directory: URL
    var commentsDirectory: URL { directory.appendingPathComponent("comments", isDirectory: true) }

    private var watchTask: Task<Void, Never>?
    private var lastSignature = ""

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mainline", isDirectory: true)) {
        self.directory = directory
    }

    deinit { watchTask?.cancel() }

    /// Seeds the folder + README when the folder is missing, loads, and starts watching.
    /// No starter comments: what a comment triggers is specific to an org's automation,
    /// so a wrongly-scoped default would post somewhere it shouldn't. Idempotent.
    func start() {
        guard watchTask == nil else { return }
        seedIfNeeded()
        reload()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.signature() != self.lastSignature { self.reload() }
            }
        }
    }

    private func seedIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: commentsDirectory.path) else { return }
        try? fm.createDirectory(at: commentsDirectory, withIntermediateDirectories: true)
        try? CommentStarters.readme.write(to: commentsDirectory.appendingPathComponent("README.txt"),
                                          atomically: true, encoding: .utf8)
    }

    private func signature() -> String {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: commentsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.sorted { $0.path < $1.path }.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(url.lastPathComponent)@\(date?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    func reload() {
        lastSignature = signature()
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: commentsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let loaded = files.compactMap { url -> CommentTemplate? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return CommentEngine.parse(fileName: url.lastPathComponent, text: text)
        }
        if loaded != templates { templates = loaded; revision &+= 1 }
    }

    // MARK: Editing (Settings)

    /// A new, unsaved comment.
    func newTemplate() -> CommentTemplate {
        let name = "New comment"
        return CommentTemplate(
            fileName: CommentEngine.fileName(forName: name, existing: Set(templates.map(\.fileName))),
            name: name,
            body: ""
        )
    }

    func save(_ template: CommentTemplate) {
        try? FileManager.default.createDirectory(at: commentsDirectory, withIntermediateDirectories: true)
        try? CommentEngine.serialize(template).write(
            to: commentsDirectory.appendingPathComponent(template.fileName), atomically: true, encoding: .utf8)
        reload()
    }

    func delete(_ template: CommentTemplate) {
        try? FileManager.default.removeItem(at: commentsDirectory.appendingPathComponent(template.fileName))
        reload()
    }

    func revealCommentsFolder() {
        seedIfNeeded()
        NSWorkspace.shared.open(commentsDirectory)
    }
}
