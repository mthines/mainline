import SwiftUI

// MARK: - PeekContentHeightKey

/// Reports the natural height of the peek card's scrollable content so the card
/// can size to it (up to a cap) instead of always filling the popover.
private struct PeekContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - PRPeekView

/// Quick-peek overlay for the focused PR (Space / context-menu "Details").
///
/// Two parts:
///   1. An **at-a-glance card** rendered instantly from `PRSnapshot` — CI, review
///      decision, mergeability, +/− lines, unresolved comments, sensitive-path
///      warnings. No network round-trip, so it answers "does this need
///      me?" immediately.
///   2. A **files-changed list** fetched async (one lightweight REST call — file
///      metadata only, not the full diff) with per-file +/− counts and a status
///      glyph.
///
/// Replaces the old raw-diff preview, which was slow on large PRs and uncolored.
/// "Open on GitHub" covers reading the actual diff comfortably.
struct PRPeekView: View {
    let pr: PRSnapshot
    let client: GitHubClient
    @Binding var isPresented: Bool
    /// Upper bound on the card height (the available popover space). The card sizes
    /// to its CONTENT and only grows to this cap — beyond it the file list scrolls.
    var maxHeight: CGFloat = 560

    @State private var files: [PRFile] = []
    @State private var isLoadingFiles: Bool = true
    @State private var filesError: String? = nil
    /// Natural (unclipped) height of the scrollable content, measured live so the
    /// scroll region can shrink to fit a short PR instead of filling the panel.
    @State private var contentHeight: CGFloat = 0

    /// Cap the rendered file rows so a giant PR can't blow up the popover.
    private let fileDisplayCap = 40

    /// Space reserved for the header + divider above the scroll region. Keeps the
    /// whole card within `maxHeight` when the content is capped.
    private let headerReserve: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.top, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    glanceCard
                    Divider().padding(.horizontal, 12).padding(.vertical, 6)
                    filesSection
                }
                .padding(.vertical, 8)
                // Measure the content's natural height (a vertical ScrollView lays
                // its content out at ideal size), so `scrollHeight` can fit it.
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PeekContentHeightKey.self,
                                               value: proxy.size.height)
                    }
                )
            }
            // Fit the content, capped so the whole card stays within `maxHeight`.
            // Short PRs → a compact card; long PRs → scroll at the cap.
            .frame(height: scrollHeight)
        }
        .onPreferenceChange(PeekContentHeightKey.self) { contentHeight = $0 }
        // Width fits inside the 360pt MenuBarExtra popover; height sizes to content
        // (see `scrollHeight`). Opaque fill so the list behind can't bleed through
        // (`.background(.background)` is translucent here).
        .frame(maxWidth: 344)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 12)
        .task { await loadFiles() }
    }

    /// Height of the scroll region: the measured content height, capped so the
    /// header + scroll region together never exceed `maxHeight`. Falls back to the
    /// cap until the first measurement arrives.
    private var scrollHeight: CGFloat {
        let cap = max(maxHeight - headerReserve, 160)
        guard contentHeight > 0 else { return cap }
        return min(contentHeight, cap)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(verbatim: "\(pr.repoFullName) #\(pr.number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                if let url = URL(string: pr.htmlUrl) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "safari").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open on GitHub")
            .accessibilityLabel("Open on GitHub")
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Glance card

    private var glanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            glanceRow(icon: ciIconName, tint: ciTint, label: "CI", value: ciText)
            glanceRow(icon: reviewIconName, tint: reviewTint, label: "Review", value: reviewText)
            glanceRow(icon: merge.icon, tint: merge.tint, label: "Merge", value: merge.text)

            // Lines + files, with red/green counts.
            HStack(spacing: 8) {
                Image(systemName: "plusminus")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("+\(pr.linesAdded)").foregroundStyle(.green)
                Text("−\(pr.linesDeleted)").foregroundStyle(.red)
                Text("· \(fileCountText)").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)

            glanceRow(
                icon: "bubble.left.and.bubble.right",
                tint: pr.unresolvedThreadCount > 0 ? .orange : .secondary,
                label: "Comments",
                value: commentsText
            )

            if let flags = pr.sensitivePathFlags, !flags.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .frame(width: 16)
                        .foregroundStyle(.yellow)
                    Text("Touches \(flags.joined(separator: ", "))")
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.callout)
            }

            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(pr.author).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Text(updatedText).foregroundStyle(.tertiary)
            }
            .font(.callout)
        }
        .padding(.horizontal, 12)
    }

    private func glanceRow(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(tint)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    // MARK: - Files section

    @ViewBuilder
    private var filesSection: some View {
        if isLoadingFiles {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading files…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        } else if let error = filesError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text(error).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(fileCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

                ForEach(Array(files.prefix(fileDisplayCap).enumerated()), id: \.offset) { _, file in
                    fileRow(file)
                }
                if files.count > fileDisplayCap {
                    Text("… \(files.count - fileDisplayCap) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func fileRow(_ file: PRFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon(for: file.status))
                .frame(width: 14)
                .foregroundStyle(statusTint(for: file.status))
                .font(.caption2)
            Text(file.filename)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text("+\(file.additions)").font(.caption2).foregroundStyle(.green)
            Text("−\(file.deletions)").font(.caption2).foregroundStyle(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func loadFiles() async {
        isLoadingFiles = true
        filesError = nil
        guard let token = await KeychainHelper.loadToken(), !token.isEmpty else {
            isLoadingFiles = false
            filesError = "No token — open Settings"
            return
        }
        do {
            files = try await client.fetchFiles(
                repoFullName: pr.repoFullName,
                number: pr.number,
                token: token
            )
        } catch GitHubAPIError.unauthorized {
            filesError = "Token lacks repo read scope — open Settings"
        } catch {
            filesError = "Couldn't load files — open on GitHub"
        }
        isLoadingFiles = false
    }

    // MARK: - Derived display

    private var fileCountText: String {
        guard !isLoadingFiles else { return "files…" }
        return files.count == 1 ? "1 file" : "\(files.count) files"
    }

    private var ciText: String {
        switch pr.ciStatus {
        case .success: return "Passing"
        case .failure: return "Failing"
        case .error:   return "Errored"
        case .pending: return "Pending"
        case .unknown: return "No checks"
        }
    }
    private var ciIconName: String {
        switch pr.ciStatus {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .error:   return "exclamationmark.circle.fill"
        case .pending: return "clock.fill"
        case .unknown: return "circle.dashed"
        }
    }
    private var ciTint: Color {
        switch pr.ciStatus {
        case .success: return .green
        case .failure, .error: return .red
        case .pending: return .orange
        case .unknown: return .secondary
        }
    }

    private var reviewText: String {
        let base: String
        switch pr.reviewDecision {
        case .approved:         base = "Approved"
        case .changesRequested: base = "Changes requested"
        case .reviewRequired:   base = "Review required"
        case .none:             base = "No review yet"
        }
        let reviewers = pr.requestedReviewers + pr.requestedTeams
        if !reviewers.isEmpty {
            return "\(base) · \(reviewers.prefix(2).joined(separator: ", "))"
        }
        return base
    }
    private var reviewIconName: String {
        switch pr.reviewDecision {
        case .approved:         return "checkmark.seal.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .reviewRequired:   return "eye.trianglebadge.exclamationmark"
        case .none:             return "eye"
        }
    }
    private var reviewTint: Color {
        switch pr.reviewDecision {
        case .approved:         return .green
        case .changesRequested: return .red
        case .reviewRequired:   return .orange
        case .none:             return .secondary
        }
    }

    /// The Merge row reflects whether the PR can *actually* be merged right now —
    /// not merely GitHub's `mergeable` flag, which only reports conflict-freeness.
    /// A conflict-free PR can still be blocked by required reviews or failing CI.
    private var merge: (text: String, icon: String, tint: Color) {
        if pr.isDraft { return ("Draft", "pencil.circle", .secondary) }
        if pr.mergeable == false { return ("Conflicts", "exclamationmark.triangle.fill", .red) }
        if pr.mergeable == nil { return ("Checking…", "questionmark.circle", .secondary) }
        // No conflicts — but is it allowed to merge?
        if pr.readyToMerge { return ("Ready to merge", "arrow.triangle.merge", .green) }
        if pr.reviewDecision != .approved { return ("Needs review", "lock.fill", .orange) }
        if pr.ciStatus != .success { return ("Blocked · CI", "lock.fill", .orange) }
        return ("Blocked", "lock.fill", .orange)
    }

    private var commentsText: String {
        if pr.unresolvedThreadCount > 0 {
            return "\(pr.unresolvedThreadCount) unresolved · \(pr.commentCount) total"
        }
        return pr.commentCount == 0 ? "None" : "\(pr.commentCount) total"
    }

    private var updatedText: String {
        let iso = ISO8601DateFormatter()
        var date = iso.date(from: pr.updatedAt)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: pr.updatedAt)
        }
        guard let date else { return "" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func statusIcon(for status: String?) -> String {
        switch status {
        case "added":    return "plus.square.fill"
        case "removed":  return "minus.square.fill"
        case "renamed":  return "arrow.left.arrow.right.square.fill"
        default:          return "square.fill"
        }
    }
    private func statusTint(for status: String?) -> Color {
        switch status {
        case "added":   return .green
        case "removed": return .red
        case "renamed": return .blue
        default:         return .secondary
        }
    }
}
