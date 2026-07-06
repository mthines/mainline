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
        MenuBarExtra("Mainline", systemImage: "arrow.triangle.pull") {
            MenuBarView(manager: manager)
                .task { await manager.start() }
                .onAppear { ManagerBridge.instance = manager }
        }
        .menuBarExtraStyle(.window)
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
