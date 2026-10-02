import Foundation
import Core

/// Abstraction over login-item removal for third-party apps.
///
/// `SMAppService` (macOS 13+) is scoped to the *calling* app's own helpers in
/// `Contents/Library/LoginItems` and cannot unregister login items belonging
/// to other apps. For an uninstaller that tears down arbitrary third-party
/// apps, the correct mechanisms are:
///   - `launchctl bootout gui/<uid>/<helperID>` — for launchd-registered
///     background helpers.
///   - `osascript` against System Events — for the legacy "Open at Login"
///     list backed by `LSSharedFileList`.
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
        // so a `com.apple.*` check does not apply here. The caller strips the
        // .app suffix and this matches by exact name.
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // No `try` wrapper: if macOS denies automation access the script must
        // fail, so a denied request isn't reported as a removed login item.
        let script = """
        tell application "System Events"
            set removedCount to 0
            repeat with i from (count of login items) to 1 by -1
                if name of login item i is "\(escaped)" then
                    delete login item i
                    set removedCount to removedCount + 1
                end if
            end repeat
            return removedCount
        end tell
        """
        let output = ProcessRunner.runBlocking("/usr/bin/osascript", ["-e", script], timeout: 120)
        guard output.succeeded else { return false }
        return (Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    public func bootoutLoginItemHelper(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        // Never boot out the protected Apple namespace regardless of what a
        // third-party helper's Info.plist claims.
        if bundleID.hasPrefix("com.apple.") {
            return false
        }
        let output = ProcessRunner.runBlocking("/bin/launchctl", ["bootout", "gui/\(getuid())/\(bundleID)"], timeout: 20)
        // `launchctl bootout` returns non-zero when the service is not
        // loaded (already gone), which is the desired end state for an
        // uninstall. Treat any completed run as success; only failing to
        // run launchctl at all is a real failure.
        return !output.launchFailed && !output.timedOut
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
