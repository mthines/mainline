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
            Spacer()
            Button("Undo") {
                entry.undo()
                entries.removeAll { $0.id == entry.id }
            }
            .buttonStyle(.plain)
            .font(.caption)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
