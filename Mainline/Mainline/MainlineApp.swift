import SwiftUI
import AppKit
import UserNotifications

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
    @ObservedObject private var trustLedger: TrustLedgerStore

    init(manager: PRManager) {
        self.manager = manager
        self.settings = manager.settings
        self.scopeStore = manager.scopeStore
        self.trustLedger = manager.trustLedger
    }

    var body: some View {
        MenuBarIconView(badge: manager.menuBarBadge)
            .help(manager.badgeExplanation)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var settingsWindow: NSWindow?

    // MARK: - Application lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        // Listen for open-settings requests from MenuBarView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsWindow),
            name: .openSettings,
            object: nil
        )

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
        window.styleMask            = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate             = self
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
