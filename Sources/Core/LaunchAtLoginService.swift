import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+) for a "Launch at
/// Login" toggle. myKikau ships unsandboxed, direct-distribution (see
/// `FullDiskAccessCheck`'s header for why), so this registers the app itself
/// to relaunch at login — no separate XPC login-item helper needed for that.
///
/// Deliberately has no persisted `AppStorage` bool of its own: `status` reads
/// macOS's actual registration state every time, so the toggle can never
/// drift from what's really registered the way a cached bool could (e.g. if
/// the user removes it via System Settings' own Login Items list instead of
/// myKikau's toggle).
public enum LaunchAtLoginService {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Returns the error on
    /// failure so the caller can revert its toggle state and explain why.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
