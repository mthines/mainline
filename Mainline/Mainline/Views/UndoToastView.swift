import SwiftUI

// MARK: - UndoEntry

/// A single undoable action entry in the toast stack.
struct UndoEntry: Identifiable {
    let id = UUID()
    let label: String
    let pr: PRSnapshot
    let undo: () -> Void
}

// MARK: - UndoToastView

/// Undo toast stack shown at the top of the triage deck (below the header/filters).
/// Displays recent actions as dismissible cards; ⌘Z undoes the last one.
struct UndoToastView: View {
    @Binding var entries: [UndoEntry]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(entries) { entry in
                toastRow(entry)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: entries.count)
    }

    private func toastRow(_ entry: UndoEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(entry.label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Undo") {
                entry.undo()
                entries.removeAll { $0.id == entry.id }
                TelemetryService.shared.recordTriageInteraction("undo")
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)

            Button {
                entries.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .toastCard()
    }
}

// MARK: - Toast card chrome

/// The shared floating-card background used by every toast (undo + info): a solid
/// base under a material blur so the PR rows beneath never bleed through, plus a
/// hairline border and drop shadow that lift it clearly above the list.
private struct ToastCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

private extension View {
    func toastCard() -> some View { modifier(ToastCard()) }
}

// MARK: - InfoToast

/// A transient, non-actionable informational toast — e.g. "Can't merge: has
/// merge conflicts". Unlike `UndoEntry` it carries no action; `PRManager` owns a
/// single optional `infoToast` and auto-dismisses it after a few seconds.
struct InfoToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
}

/// Renders the current `InfoToast` as a floating card matching the undo toast,
/// with a warning glyph and a manual dismiss button.
struct InfoToastView: View {
    let toast: InfoToast
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .foregroundStyle(Color(nsColor: .systemOrange))
                .font(.caption)
            Text(toast.message)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .toastCard()
    }
}
