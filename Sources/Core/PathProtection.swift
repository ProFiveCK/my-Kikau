import Foundation

/// Protects system paths, user data, security agents and critical bundle IDs
/// from modification or deletion.
///
/// `shouldProtect` is the backstop behind every deletion: `SafeFileDeleter`
/// checks it when a plan is built and again when the plan is executed. It
/// compares both the standardised path and the symlink-resolved path, so a
/// `..` segment or a link that leads into a protected tree is still caught.
public struct PathProtection: Sendable {
    public static let shared = PathProtection()

    private let home: String
    private let exclusions: @Sendable () -> [String]
    private let extraBundlePrefixes: @Sendable () -> [String]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        exclusions: @escaping @Sendable () -> [String] = { ExclusionStore.shared.normalisedPaths },
        extraBundlePrefixes: @escaping @Sendable () -> [String] = { ManagedPolicy.shared.protectedBundlePrefixes }
    ) {
        self.home = Self.normalise(home.path)
        self.exclusions = exclusions
        self.extraBundlePrefixes = extraBundlePrefixes
    }

    /// Subtrees that must never be modified or deleted. Stored in normalised
    /// form (no `/private` prefix — see `normalise`).
    private static let protectedSubtrees: [String] = [
        "/System",
        "/Library/Apple",
        "/Library/AppleInternal",
        "/Library/Updates",
        "/Library/Keychains",
        "/Library/Application Support/com.apple.TCC",
        "/macOS Install Data",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/var/db",
        "/cores",
    ]

    /// Containers that must never be deleted themselves; their contents are
    /// judged individually.
    private static let protectedContainers: Set<String> = [
        "/", "/Users", "/Users/Shared", "/Applications", "/Applications/Utilities", "/Library",
        "/Volumes", "/opt", "/var", "/var/folders", "/tmp", "/private",
    ]

    /// Home-relative containers that must never be deleted themselves.
    private static let protectedHomeContainers: [String] = [
        "", "Library", "Library/Application Support", "Library/Caches", "Library/Preferences",
        "Library/Containers", "Library/Group Containers", "Library/Logs", "Library/LaunchAgents",
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Applications", ".Trash",
    ]

    /// Home-relative subtrees holding credentials or irreplaceable user data.
    private static let protectedHomeSubtrees: [String] = [
        "Library/Keychains",
        "Library/Mail",
        "Library/Messages",
        "Library/Mobile Documents",
        "Library/Application Support/com.apple.TCC",
        "Library/Logs/myKikau",
        ".ssh",
        ".gnupg",
    ]

    /// Critical system bundle IDs protected from uninstallation.
    /// Explicitly listed (not `com.apple.*` wildcard) so user-installed Apple
    /// apps (Xcode, Final Cut Pro) can still be uninstalled.
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

    /// Endpoint security / EDR / MDM bundle prefixes. Anything these agents
    /// own — caches, preferences, containers, launch plists — must never be
    /// touched: removing it trips tamper detection or breaks device management.
    private static let endpointSecurityBundlePrefixes: [String] = [
        "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.",
        "com.eset.", "com.jamf.", "com.jamfsoftware.",
        "com.microsoft.wdav", "com.microsoft.intune", "com.microsoft.CompanyPortal",
        "com.sophos.", "com.paloaltonetworks.", "com.carbonblack.", "com.vmware.carbonblack",
        "com.cisco.amp", "com.cisco.secureclient", "com.cisco.anyconnect",
        "com.kandji.", "io.kandji.", "com.mosyle.", "com.addigy.", "com.hexnode.",
        "com.trendmicro.", "com.symantec.", "com.broadcom.", "com.mcafee.", "com.trellix.",
        "com.bitdefender.", "com.malwarebytes.", "com.elastic.", "co.elastic.",
        "com.tanium.", "com.zscaler.", "com.netskope.", "com.fortinet.", "com.checkpoint.",
        "com.cybereason.", "com.fireeye.", "com.rapid7.", "com.qualys.", "com.tenable.",
    ]

    private static let endpointPrefixesLowercased = endpointSecurityBundlePrefixes.map { $0.lowercased() }

    // MARK: - Paths

    /// Returns true if the given URL points to a protected path.
    public func shouldProtect(_ url: URL) -> Bool {
        let standardised = Self.normalise(url.standardizedFileURL.path)
        if isProtected(standardised) {
            return true
        }
        let resolved = Self.normalise(url.resolvingSymlinksInPath().path)
        return resolved != standardised && isProtected(resolved)
    }

    /// Returns true if any component of the path belongs to an endpoint
    /// security or device-management agent.
    public func isEndpointSecurityPath(_ url: URL) -> Bool {
        hasEndpointSecurityComponent(Self.normalise(url.standardizedFileURL.path))
    }

    /// A path is protected if it is a protected root, is inside one, or
    /// *contains* one — removing a folder removes everything in it, so a
    /// folder holding an excluded or protected item can't be removed whole.
    private func isProtected(_ path: String) -> Bool {
        if path.isEmpty || Self.protectedContainers.contains(path) {
            return true
        }
        for prefix in Self.protectedSubtrees where Self.overlaps(path, prefix) {
            return true
        }
        for relative in Self.protectedHomeContainers where path == homePath(relative) {
            return true
        }
        for relative in Self.protectedHomeSubtrees where Self.overlaps(path, homePath(relative)) {
            return true
        }
        // Exclusions are compared without regard to case: the default macOS
        // volume format is case-insensitive, so "keep" and "Keep" are one folder.
        let lowered = path.lowercased()
        for excluded in exclusions() where Self.overlaps(lowered, excluded.lowercased()) {
            return true
        }
        return hasEndpointSecurityComponent(path)
    }

    /// True if one path is the other, or either contains the other.
    private static func overlaps(_ path: String, _ root: String) -> Bool {
        isSameOrInside(path, root) || isSameOrInside(root, path)
    }

    /// Looks one and two levels inside a folder for anything owned by a
    /// security or device-management agent. `shouldProtect` judges a path by
    /// its own name; this catches an agent's folder nested inside a vendor
    /// cache or log folder that is about to be removed whole.
    public func containsEndpointSecurityItem(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return false }
        for child in children.prefix(2000) {
            if hasEndpointSecurityComponent("/" + child.lastPathComponent) {
                return true
            }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let grandchildren = try? fileManager.contentsOfDirectory(atPath: child.path) else { continue }
            if grandchildren.prefix(2000).contains(where: { hasEndpointSecurityComponent("/" + $0) }) {
                return true
            }
        }
        return false
    }

    private func hasEndpointSecurityComponent(_ path: String) -> Bool {
        let prefixes = Self.endpointPrefixesLowercased + extraBundlePrefixes().map { $0.lowercased() }
        for component in path.split(separator: "/") {
            // Group containers carry a Team ID in front of the bundle ID
            // ("ABCDE12345.com.vendor.agent"), so check both forms.
            let name = component.lowercased()
            let stripped = Self.strippingTeamID(String(component)).lowercased()
            if prefixes.contains(where: { name.hasPrefix($0) || stripped.hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    private func homePath(_ relative: String) -> String {
        relative.isEmpty ? home : home + "/" + relative
    }

    private static func isSameOrInside(_ path: String, _ root: String) -> Bool {
        guard !root.isEmpty else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    /// Drops a leading Team ID label, if there is one. A Team ID is exactly
    /// ten characters, upper-case letters and digits only — an ordinary
    /// ten-letter word ("university") is not one.
    public static func strippingTeamID(_ name: String) -> String {
        guard let dot = name.firstIndex(of: "."), name.distance(from: name.startIndex, to: dot) == 10 else {
            return name
        }
        let team = name[name.startIndex ..< dot]
        guard team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return name }
        return String(name[name.index(after: dot)...])
    }

    /// Canonical form used for every comparison: no trailing slash, and no
    /// `/private` in front of `/var`, `/tmp` or `/etc` (which are links to the
    /// same directories — Foundation strips the prefix inconsistently).
    public static func normalise(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        for alias in ["/var", "/tmp", "/etc"] {
            let aliased = "/private" + alias
            if result == aliased || result.hasPrefix(aliased + "/") {
                result.removeFirst("/private".count)
                break
            }
        }
        return result
    }

    // MARK: - Bundle IDs

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

    /// Returns true if the bundle ID belongs to an endpoint security or
    /// device-management agent.
    public func isEndpointSecurityBundle(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return (Self.endpointPrefixesLowercased + extraBundlePrefixes().map { $0.lowercased() })
            .contains { id.hasPrefix($0) }
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
                if !value.hasPrefix(part) {
                    return false
                }
                current = value.index(value.startIndex, offsetBy: part.count)
            } else if i == parts.count - 1 {
                if !value.hasSuffix(part) {
                    return false
                }
                let remaining = value.distance(from: current, to: value.endIndex)
                if remaining < part.count {
                    return false
                }
            } else {
                if let range = value.range(of: part, range: current ..< value.endIndex) {
                    current = range.upperBound
                } else {
                    return false
                }
            }
        }
        return true
    }
}
