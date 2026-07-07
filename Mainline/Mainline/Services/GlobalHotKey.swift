import AppKit
import Carbon.HIToolbox

// MARK: - GlobalHotKey

/// A tiny Carbon-based global (system-wide) hotkey service.
///
/// Uses `RegisterEventHotKey` + `InstallEventHandler` for the
/// `kEventClassKeyboard` / `kEventHotKeyPressed` event. This approach does NOT
/// require the Accessibility permission (unlike `CGEvent` taps or
/// `NSEvent.addGlobalMonitorForEvents`), which is why it is preferred for a
/// menu-bar utility that should "just work" on first launch.
///
/// Register a hotkey for a given `(keyCode, carbonModifiers)` pair; the supplied
/// callback fires on the main thread whenever the combo is pressed anywhere in
/// the system. Call `unregister()` to tear it down (also called on `deinit`).
final class GlobalHotKey {

    /// Invoked on the main thread when the registered hotkey is pressed.
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// A process-unique signature + id so the Carbon handler can match presses
    /// to this instance. The four-char signature is arbitrary but stable.
    private let hotKeyID = EventHotKeyID(signature: OSType(0x4D4C4E48 /* "MLNH" */), id: 1)

    init() {}

    deinit {
        unregister()
    }

    // MARK: - Registration

    /// Register a system-wide hotkey. Any previously registered combo is removed
    /// first, so this doubles as "re-register" when the user changes the combo.
    /// - Parameters:
    ///   - keyCode: A virtual key code (e.g. `kVK_ANSI_P` = 0x23).
    ///   - modifiers: A Carbon modifier mask (`cmdKey | shiftKey | …`).
    func register(keyCode: UInt32, modifiers: UInt32) {
        // Always start from a clean slate so re-registration doesn't leak.
        unregister()

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("GlobalHotKey: RegisterEventHotKey failed (status \(status)) — combo may be reserved by the system.")
        }
    }

    /// Remove the registered hotkey and the shared event handler.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    // MARK: - Carbon event handler

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Pass an unretained pointer to self so the C callback can route the
        // press back to this instance without a retain cycle.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }

                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr else { return noErr }

                let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard pressedID.id == instance.hotKeyID.id,
                      pressedID.signature == instance.hotKeyID.signature else { return noErr }

                // Carbon dispatches on the main run loop, but hop explicitly to
                // be safe for UI work in the callback.
                DispatchQueue.main.async {
                    instance.onPress?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }

    // MARK: - Modifier conversion

    /// Convert Cocoa `NSEvent.ModifierFlags` into a Carbon modifier mask suitable
    /// for `RegisterEventHotKey`.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command)  { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)    { carbon |= UInt32(shiftKey) }
        if flags.contains(.control)  { carbon |= UInt32(controlKey) }
        if flags.contains(.option)   { carbon |= UInt32(optionKey) }
        return carbon
    }
}

// MARK: - MenuBarPopoverOpener

/// Programmatically opens the app's `MenuBarExtra` popover.
///
/// `MenuBarExtra` (macOS 13) exposes no public API to open its popover from
/// code, so this relies on private view internals: it locates the app's
/// `NSStatusBarButton` and simulates a click. This is the approved dependency-
/// free tradeoff — it touches AppKit internals (the status-bar window class and
/// view hierarchy) and MAY need updating on a future macOS if those internals
/// change. Everything is guarded (optionals, no force-unwraps); if the button
/// can't be found it degrades to merely activating the app and logging.
@MainActor
enum MenuBarPopoverOpener {

    /// Bring the app forward and open (or toggle) the menu-bar popover.
    static func open() {
        NSApp.activate(ignoringOtherApps: true)

        guard let button = findStatusItemButton() else {
            NSLog("MenuBarPopoverOpener: status-item button not found — app activated only.")
            return
        }

        // `performClick` toggles the MenuBarExtra popover. If it is already open
        // this closes it (acceptable toggle behavior); otherwise it opens it.
        button.performClick(nil)
    }

    /// Walk `NSApp.windows` for the status-bar window (its class name contains
    /// "StatusBar") and find the `NSStatusBarButton` inside its content view.
    private static func findStatusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            let className = String(describing: type(of: window))
            guard className.contains("StatusBar") else { continue }
            if let contentView = window.contentView,
               let button = firstStatusBarButton(in: contentView) {
                return button
            }
        }
        // Fallback: some macOS versions don't surface the status window in
        // `NSApp.windows`; scan every window's hierarchy as a last resort.
        for window in NSApp.windows {
            if let contentView = window.contentView,
               let button = firstStatusBarButton(in: contentView) {
                return button
            }
        }
        return nil
    }

    /// Depth-first search for the first `NSStatusBarButton` in a view subtree.
    private static func firstStatusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let found = firstStatusBarButton(in: subview) {
                return found
            }
        }
        return nil
    }
}
