import SwiftUI
import AppKit

// MARK: - KeyboardShortcutsView

/// Settings pane for configuring all in-popover keyboard shortcuts. Each action
/// shows its current binding with an `InAppShortcutRecorder`; clashing bindings
/// are highlighted in red and the Save button is disabled until all clashes are
/// resolved. A "Reset All to Defaults" button restores factory bindings.
struct KeyboardShortcutsView: View {
    @ObservedObject var settings: MainlineSettings

    /// Working copy — edits apply here until Save is tapped.
    @State private var draft: InAppShortcutBindings = .defaults

    private var clashingShortcuts: Set<InAppShortcut> {
        draft.clashingShortcuts
    }

    private var canSave: Bool {
        draft.isValid
    }

    @ViewBuilder
    private func shortcutRow(for shortcut: InAppShortcut) -> some View {
        let isClashing = clashingShortcuts.contains(shortcut)
        HStack {
            Image(systemName: shortcut.symbolName)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(shortcut.displayName)
            Spacer()
            InAppShortcutRecorder(
                binding: Binding(
                    get: { draft.binding(for: shortcut) },
                    set: { newBinding in draft.setBinding(newBinding, for: shortcut) }
                ),
                isClashing: isClashing
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isClashing ? Color(nsColor: .systemRed).opacity(0.08) : Color.clear)
        )
        .help(isClashing ? "This key clashes with another shortcut" : "")
    }

    var body: some View {
        Section("In-App Shortcuts") {
            Text("Customize the keyboard shortcuts used inside the Mainline popover. Each binding can be a bare key or include modifiers (⌘ ⇧ ⌃ ⌥).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(InAppShortcut.allCases, id: \.id) { shortcut in
                shortcutRow(for: shortcut)
            }

            HStack {
                Button("Reset All to Defaults") {
                    draft = .defaults
                }

                Spacer()

                if !canSave {
                    Label("Clashing keys — resolve to save", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Save") {
                    settings.shortcutBindings = draft
                }
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .onAppear {
            draft = settings.shortcutBindings
        }
    }
}

// MARK: - InAppShortcutRecorder

/// A button that captures the next key press (single character plus any
/// combination of ⌘⇧⌃⌥ modifiers) and stores it as the new binding. Bare
/// keys (no modifiers) and modified keys (e.g. ⌘Z) are both accepted.
/// Escape cancels without changing the binding. Mirrors the global-hotkey
/// recorder in SettingsView, but does NOT require a non-empty modifier set —
/// bare keys are valid for in-app shortcuts.
struct InAppShortcutRecorder: View {
    @Binding var binding: ShortcutBinding
    var isClashing: Bool = false

    @State private var isRecording = false
    @State private var monitor: Any?

    private var displayLabel: String {
        if isRecording { return "Press a key…" }
        return MainlineSettings.glyph(for: binding)
    }

    var body: some View {
        Button(action: toggleRecording) {
            Text(displayLabel)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 72)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : (isClashing ? .red : nil))
        .help(isRecording ? "Press a key (with optional ⌘⇧⌃⌥), or Escape to cancel" : "Click to record a new shortcut")
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
        // Escape cancels without changing the binding.
        if event.keyCode == 0x35 {
            stopRecording()
            return
        }

        // Accept only single-character inputs (guard against IME multi-char sequences).
        let chars = event.charactersIgnoringModifiers ?? ""
        guard chars.count == 1 else { return }

        // Capture modifiers (masked to relevant set — ⌘⇧⌃⌥ only), mirroring the
        // global-hotkey recorder in SettingsView.swift.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(ShortcutBinding.relevantModifierMask)

        binding = ShortcutBinding(key: chars.lowercased(), modifiers: mods.rawValue)
        stopRecording()
    }
}
