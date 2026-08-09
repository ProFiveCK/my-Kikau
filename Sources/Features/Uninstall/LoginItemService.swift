import Foundation

/// Abstraction over login-item removal for third-party apps.
///
/// `SMAppService` (macOS 13+) is scoped to the *calling* app's own helpers in
/// `Contents/Library/LoginItems` and cannot unregister login items belonging
/// to other apps. For an uninstaller that tears down arbitrary third-party
/// apps, the correct mechanisms are:
///   - `launchctl bootout gui/<uid>/<helperID>` — for launchd-registered
///     background helpers (mirrors Mole's `bootout_login_item_helpers`).
///   - `osascript` against System Events — for the legacy "Open at Login"
///     list backed by `LSSharedFileList` (mirrors Mole's `remove_login_item`).
///
/// The protocol seam exists so tests can inject a stub that records calls
/// without spawning `launchctl` or `osascript` (the latter triggers an
/// AppleScript automation permission prompt).
public protocol LoginItemManaging: AnyObject {
    /// Removes a legacy Open-at-Login entry by display name.
    /// Returns true if an item was removed (or would be, in dry-run).
    /// `com.apple.*` names are never removed.
    func removeLoginItemByName(_ name: String) -> Bool

    /// Boots out a launchd-registered background helper by bundle ID.
    /// Returns true on success (or would-bootout in dry-run).
    /// `com.apple.*` labels are never booted out.
    func bootoutLoginItemHelper(bundleID: String) -> Bool
}

/// Real implementation backed by `launchctl` and `osascript`.
public final class SystemEventsLoginItemService: LoginItemManaging {
    public init() {}

    public func removeLoginItemByName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        // System Events login items are keyed by display name, not bundle ID,
        // so a `com.apple.*` check does not apply here. Mole strips the .app
        // suffix and matches by name; an Apple system app name is unlikely to
        // be a user-managed login item, and removing it is reversible via
        // System Settings if it ever happens.
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            try
                set itemCount to count of login items
                repeat with i from itemCount to 1 by -1
                    try
                        if name of login item i is "\(escaped)" then
                            delete login item i
                        end if
                    end try
                end repeat
            end try
        end tell
        """
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    public func bootoutLoginItemHelper(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        // Never boot out the protected Apple namespace regardless of what a
        // third-party helper's Info.plist claims.
        if bundleID.hasPrefix("com.apple.") { return false }
        let uid = getuid()
        let label = "gui/\(uid)/\(bundleID)"
        let process = Process()
        process.launchPath = "/bin/launchctl"
        process.arguments = ["bootout", label]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            // `launchctl bootout` returns non-zero when the service is not
            // loaded (already gone), which is the desired end state for an
            // uninstall. Treat any completed run as success; only a launch
            // failure (throw) is a real failure. Mole ignores the exit code
            // the same way and only aborts on timeout (124/128+).
            return true
        } catch {
            return false
        }
    }
}

/// Test double that records calls without spawning `launchctl` or `osascript`.
public final class StubLoginItemService: LoginItemManaging {
    public var bootoutCalls: [String] = []
    public var removeByNameCalls: [String] = []
    public var bootoutResult: Bool = true
    public var removeByNameResult: Bool = true

    public init() {}

    public func removeLoginItemByName(_ name: String) -> Bool {
        removeByNameCalls.append(name)
        return removeByNameResult
    }

    public func bootoutLoginItemHelper(bundleID: String) -> Bool {
        bootoutCalls.append(bundleID)
        return bootoutResult
    }
}