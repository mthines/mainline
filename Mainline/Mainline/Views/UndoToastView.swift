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

/// Undo toast stack shown at the bottom of the triage deck.
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Opaque floating card: a solid base under a material blur so the PR
        // rows/section headers beneath the toast never bleed through (the old
        // translucent `.quaternary` fill let them ghost into view). A hairline
        // border and drop shadow lift it clearly above the list.
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
