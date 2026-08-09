import Foundation

/// Protects system paths and critical bundle IDs from modification or deletion.
/// Mirrors Mole's `lib/core/app_protection.sh` + `app_protection_data.sh`.
public struct PathProtection {
    public static let shared = PathProtection()

    /// Absolute path prefixes that must never be modified or deleted.
    private let protectedPathPrefixes: [String] = [
        "/System",
        "/Library/Apple",
        "/Library/AppleInternal",
        "/private/var/db/powerlog",
        "/Library/Updates",
        "/macOS Install Data",
        "/usr",
        "/bin",
        "/sbin",
    ]

    /// Critical system bundle IDs protected from uninstallation.
    /// Explicitly listed (not `com.apple.*` wildcard) so user-installed Apple
    /// apps (Xcode, Final Cut Pro) can still be uninstalled.
    /// Ported from Mole's SYSTEM_CRITICAL_BUNDLES.
    private let systemCriticalBundles: [String] = [
        "com.apple.finder", "com.apple.dock", "com.apple.Safari", "com.apple.mail",
        "com.apple.systempreferences", "com.apple.SystemSettings", "com.apple.Settings*",
        "com.apple.controlcenter*", "com.apple.Spotlight", "com.apple.notificationcenterui",
        "com.apple.loginwindow", "com.apple.Preview", "com.apple.TextEdit", "com.apple.Notes",
        "com.apple.reminders", "com.apple.iCal", "com.apple.AddressBook", "com.apple.Photos",
        "com.apple.AppStore", "com.apple.calculator", "com.apple.Dictionary",
        "com.apple.ScreenSharing", "com.apple.ActivityMonitor", "com.apple.Console",
        "com.apple.DiskUtility", "com.apple.KeychainAccess", "com.apple.DigitalColorMeter",
        "com.apple.grapher", "com.apple.Terminal", "com.apple.ScriptEditor2",
        "com.apple.VoiceOverUtility", "com.apple.BluetoothFileExchange",
        "com.apple.print.PrinterProxy", "com.apple.systempreferences*",
        "com.apple.SystemProfiler", "com.apple.FontBook", "com.apple.ColorSyncUtility",
        "com.apple.audio.AudioMIDISetup", "com.apple.Directoryutility", "com.apple.NetworkUtility",
        "com.apple.exposelauncher", "com.apple.MigrateAssistant", "com.apple.RAIDUtility",
        "com.apple.BootCampAssistant", "com.apple.bootcampassistant",
        "com.apple.SecurityAgent", "com.apple.CoreServices*", "com.apple.SystemUIServer",
        "com.apple.backgroundtaskmanagement*", "com.apple.loginitems*",
        "com.apple.sharedfilelist*", "com.apple.sfl*", "com.apple.coreservices*",
        "com.apple.metadata*", "com.apple.MobileSoftwareUpdate*", "com.apple.SoftwareUpdate*",
        "com.apple.installer*", "com.apple.frameworks*", "com.apple.security*",
        "com.apple.keychain*", "com.apple.trustd*", "com.apple.securityd*",
        "com.apple.cloudd*", "com.apple.iCloud*", "com.apple.WiFi*", "com.apple.airport*",
        "com.apple.Bluetooth*", "com.apple.inputmethod.*", "com.apple.inputsource*",
        "com.apple.TextInput*", "com.apple.CharacterPicker*", "com.apple.PressAndHold*",
        "loginwindow", "dock", "systempreferences", "finder",
        "backgroundtaskmanagementagent", "keychain*", "security*", "bluetooth*",
        "wifi*", "network*", "tcc", "notification*", "accessibility*",
        "universalaccess*", "HIToolbox*", "textinput*", "TextInput*",
        "keyboard*", "Keyboard*", "inputsource*", "InputSource*",
        "keylayout*", "KeyLayout*", "GlobalPreferences", ".GlobalPreferences",
    ]

    /// Endpoint security / EDR / MDM bundle prefixes. Their per-user Darwin
    /// caches under /private/var/folders must never be deleted (tamper detection).
    private let endpointSecurityBundlePrefixes: [String] = [
        "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.",
        "com.eset.", "com.jamf.",
    ]

    /// Returns true if the given URL points to a protected path.
    public func shouldProtect(_ url: URL) -> Bool {
        let path = url.path
        for prefix in protectedPathPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }

    /// Returns true if the bundle ID is a critical system bundle.
    /// Matching is case-sensitive (macOS reports inconsistent casing across releases).
    public func isSystemCriticalBundle(_ bundleID: String) -> Bool {
        for pattern in systemCriticalBundles {
            if matches(bundleID, pattern: pattern) {
                return true
            }
        }
        return false
    }

    /// Returns true if the bundle ID belongs to an endpoint security agent
    /// whose caches must not be touched (tamper detection).
    public func isEndpointSecurityBundle(_ bundleID: String) -> Bool {
        for prefix in endpointSecurityBundlePrefixes {
            if bundleID.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    /// Glob match with `*` wildcard support (case-sensitive).
    private func matches(_ value: String, pattern: String) -> Bool {
        guard pattern.contains("*") else {
            return value == pattern
        }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        if parts.count == 1 {
            return pattern.hasSuffix("*") ? value.hasPrefix(parts[0]) : value == parts[0]
        }
        var current = value.startIndex
        for (i, part) in parts.enumerated() {
            if i == 0 {
                if !value.hasPrefix(part) { return false }
                current = value.index(value.startIndex, offsetBy: part.count)
            } else if i == parts.count - 1 {
                if !value.hasSuffix(part) { return false }
                let remaining = value.distance(from: current, to: value.endIndex)
                if remaining < part.count { return false }
            } else {
                if let range = value.range(of: part, range: current..<value.endIndex) {
                    current = range.upperBound
                } else {
                    return false
                }
            }
        }
        return true
    }
}