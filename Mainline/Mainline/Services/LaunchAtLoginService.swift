import Foundation
import ServiceManagement

/// Manages registering / unregistering the app as a login item via
/// `SMAppService` (macOS 13+). Pure service — no SwiftUI dependency.
/// Call `apply(enabled:)` to sync the system state to the desired value.
enum LaunchAtLoginService {

    /// The current system registration status. `true` when the app is enrolled
    /// as a login item (status == .enabled). Does NOT reflect UserDefaults —
    /// it reads directly from the system.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item to match `enabled`.
    /// Safe to call multiple times; registers only when not already enrolled,
    /// and unregisters only when currently enrolled. Logs failures to stderr.
    static func apply(enabled: Bool) {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            do {
                try SMAppService.mainApp.register()
            } catch {
                fputs("[LaunchAtLogin] register failed: \(error)\n", stderr)
            }
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                fputs("[LaunchAtLogin] unregister failed: \(error)\n", stderr)
            }
        }
    }
}
