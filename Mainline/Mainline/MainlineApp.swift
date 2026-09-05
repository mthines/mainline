import SwiftUI
import AppKit
import UserNotifications
import Combine

// A simple nonisolated bridge so AppDelegate (created before the SwiftUI scene)
// can reach the @StateObject manager once the scene has initialised it.
// Using a plain var (not @MainActor) avoids concurrency annotations on AppDelegate.
private enum ManagerBridge {
    static weak var instance: PRManager?
}

@main
struct MainlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = PRManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
                // Guarded fallback only — `start()` is idempotent, so the
                // real initial start happens on the always-rendered label
                // below, independent of popover visibility.
                .task { await manager.start() }
                .onAppear { ManagerBridge.instance = manager }
        } label: {
            MenuBarLabel(manager: manager)
                // The menu-bar icon is always rendered, so this task begins
                // polling at launch regardless of whether the popover is
                // opened. Idempotent — a second call is a no-op.
                .task {
                    ManagerBridge.instance = manager
                    await manager.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - MenuBarLabel

/// Observes the manager and the nested stores that drive the scope-aware,
/// metric-configurable badge so the menu-bar icon updates live when the user
/// changes scope (chip tap / `[` `]`), metric, or when PRs refresh.
private struct MenuBarLabel: View {
    @ObservedObject var manager: PRManager
    @ObservedObject private var settings: MainlineSettings
    @ObservedObject private var scopeStore: ScopeStore

    init(manager: PRManager) {
        self.manager = manager
        self.settings = manager.settings
        self.scopeStore = manager.scopeStore
    }

    var body: some View {
        MenuBarIconView(badge: manager.menuBarBadge)
            .help(manager.badgeExplanation)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var settingsWindow: NSWindow?

    // MARK: - Global hotkey

    private let globalHotKey = GlobalHotKey()
    private var shortcutObservers: [AnyCancellable] = []

    // MARK: - Application lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        // Verify InboxMuteEngine invariants at launch in DEBUG builds.
        // This is a no-op in Release. Assertion failures here indicate a logic
        // regression in the pure mute engine.
        #if DEBUG
        InboxMuteEngine.runSelfChecks()
        PRClassificationChecks.run()
        AttentionPolicyChecks.run()
        NotificationRoutingChecks.run()
        PreviewDetectionChecks.run()
        #endif

        // Listen for open-settings requests from MenuBarView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsWindow),
            name: .openSettings,
            object: nil
        )

        // Configure telemetry if already opted in (re-enable across launches).
        TelemetryService.shared.configure()

        // Record app launch (no-op when telemetry is disabled).
        TelemetryService.shared.recordAppLaunch()

        // Global shortcut: register now (if enabled) and re-register whenever the
        // stored combo or the enabled flag changes.
        setUpGlobalHotKey()

        // Kick off fetching the moment the app launches — independent of whether
        // the popover is ever opened. The MenuBarLabel `.task` also calls
        // `start()`, but that only fires once SwiftUI renders the scene; this
        // launch-time path guarantees the FIRST poll begins right away. `start()`
        // is idempotent (guarded by `didStart`), so the two paths never double-poll.
        startManagerAtLaunch()
    }

    /// Triggers `PRManager.start()` at launch via the nonisolated bridge. The
    /// bridge is populated when the SwiftUI scene initialises the manager, which
    /// may be slightly after `applicationDidFinishLaunching`; retry briefly until
    /// it is available (mirrors `openSettingsWindow`'s wait).
    private func startManagerAtLaunch(attempt: Int = 0) {
        guard let manager = ManagerBridge.instance else {
            guard attempt < 20 else { return }   // give up after ~2s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startManagerAtLaunch(attempt: attempt + 1)
            }
            return
        }
        Task { await manager.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        globalHotKey.unregister()
        TelemetryService.shared.shutdown()
    }

    // MARK: - Global hotkey wiring

    /// Wire the global hotkey to `MainlineSettings.shared`: subscribe to the three
    /// relevant published properties so any change (from the recorder, the toggle,
    /// or the reset button) live re-registers the Carbon hotkey, and perform an
    /// initial registration immediately.
    private func setUpGlobalHotKey() {
        globalHotKey.onPress = {
            // `onPress` is delivered on the main thread, but hop through a
            // MainActor task so the compiler is satisfied and the call is safe.
            Task { @MainActor in
                TelemetryService.shared.recordGlobalShortcutUsed()
                MenuBarPopoverOpener.open()
            }
        }

        let settings = MainlineSettings.shared
        // `receive(on:.main)` + `dropFirst` on each publisher would still fire on
        // the initial value; instead we do one explicit apply now, then react to
        // subsequent changes. Combine's @Published emits the NEW value in
        // willSet, so debounce a tiny bit to coalesce multi-property updates
        // (e.g. reset sets keyCode + modifiers together).
        Publishers.Merge3(
            settings.$globalShortcutEnabled.map { _ in () },
            settings.$globalShortcutKeyCode.map { _ in () },
            settings.$globalShortcutModifiers.map { _ in () }
        )
        .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.applyGlobalHotKey()
        }
        .store(in: &shortcutObservers)

        applyGlobalHotKey()
    }

    /// Register or unregister the Carbon hotkey to match current settings.
    private func applyGlobalHotKey() {
        let settings = MainlineSettings.shared
        guard settings.globalShortcutEnabled else {
            globalHotKey.unregister()
            return
        }
        let carbonMods = GlobalHotKey.carbonModifiers(from: settings.globalShortcutModifierFlags)
        globalHotKey.register(
            keyCode: UInt32(settings.globalShortcutKeyCode),
            modifiers: carbonMods
        )
    }

    // MARK: - Settings window

    @objc func openSettingsWindow() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let manager = ManagerBridge.instance else {
            // Manager not yet set up — open after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openSettingsWindow()
            }
            return
        }

        let settingsView = SettingsView(manager: manager)
        let controller   = NSHostingController(rootView: settingsView)
        let window       = NSWindow(contentViewController: controller)
        window.title                = "Mainline Settings"
        window.styleMask            = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate             = self
        // Larger, resizable, sidebar-friendly window. The hosting SettingsView
        // fills this via its NavigationSplitView (no fixed inner frame), so the
        // sidebar + detail pane use the full content area.
        window.setContentSize(NSSize(width: 720, height: 560))
        window.minSize              = NSSize(width: 640, height: 480)
        window.center()

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == NotificationService.openActionId ||
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Revert activation policy to accessory after settings closes
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.settingsWindow, !window.isVisible else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
