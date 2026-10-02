import Foundation
import Core

/// Finds leftover files for an app by exact bundle ID match.
/// Exact bundle-ID or exact-path evidence only.
/// Never uses vendor-prefix or generic-name wildcards (per AGENTS.md safety rule).
///
/// "Exact" means the entry's name *is* the bundle ID, optionally followed by
/// a known file extension (`.plist`, `.savedState`, …) or wrapped in a group
/// container's `group.` / Team-ID prefix. A longer identifier that merely
/// starts with the bundle ID — `com.google.Chrome.canary` when uninstalling
/// `com.google.Chrome` — is a different app and is never matched. Helpers the
/// app ships inside its own bundle are matched by *their* exact IDs, read
/// from the bundle before it's removed.
public enum LeftoverFinder {
    /// Locations under ~/Library that may contain app leftovers.
    public static let librarySearchPaths: [String] = [
        "Application Support",
        "Caches",
        "Preferences",
        "Logs",
        "Saved Application State",
        "HTTPStorages",
        "WebKit",
        "Containers",
        "Group Containers",
        "Application Scripts",
        "Cookies"
    ]

    /// System-level launch agent/daemon locations. Removing anything here
    /// needs administrator rights, so these are reported, never planned.
    public static let launchPaths: [String] = [
        "/Library/LaunchDaemons",
        "/Library/LaunchAgents",
        "/Library/PrivilegedHelperTools"
    ]

    /// User-level launch agent locations.
    public static var userLaunchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/LaunchAgents").path]
    }

    /// File extensions that may follow a bundle ID in a leftover's name.
    /// Anything else after the ID is another identifier label, i.e. a
    /// different bundle.
    static let leftoverExtensions: Set<String> = [
        "plist", "savedState", "binarycookies", "json", "db", "sqlite", "log",
        "lockfile", "plist.lockfile", "sfl2", "sfl3"
    ]

    /// Sub-bundle locations inside an `.app` whose identifiers count as the
    /// app's own.
    private static let embeddedBundleLocations: [(path: String, extensions: Set<String>)] = [
        ("Contents/Library/LoginItems", ["app"]),
        ("Contents/XPCServices", ["xpc"]),
        ("Contents/PlugIns", ["appex", "plugin"]),
        ("Contents/Helpers", ["app"]),
        ("Contents/Frameworks", ["app"]),
        ("Contents/Library/LaunchServices", ["app"])
    ]

    /// A bundle ID is usable as leftover evidence only if it's a real
    /// reverse-DNS identifier that isn't a critical system bundle or a
    /// security agent. A one-label ID ("com") would otherwise match half of
    /// `~/Library/Preferences`.
    public static func isUsableBundleID(_ bundleID: String) -> Bool {
        let labels = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && !$0.contains(" ") && !$0.contains("/") }) else {
            return false
        }
        let protection = PathProtection.shared
        return !protection.isSystemCriticalBundle(bundleID) && !protection.isEndpointSecurityBundle(bundleID)
    }

    /// Bundle IDs of helpers, XPC services and extensions shipped inside the
    /// app bundle. Exact evidence: read from each sub-bundle's Info.plist.
    public static func embeddedBundleIDs(appURL: URL) -> [String] {
        let fm = FileManager.default
        var ids: [String] = []
        for location in embeddedBundleLocations {
            let dir = appURL.appendingPathComponent(location.path)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where location.extensions.contains(entry.pathExtension) {
                guard let id = Bundle(url: entry)?.bundleIdentifier,
                      !id.hasPrefix("com.apple."),
                      isUsableBundleID(id),
                      !ids.contains(id) else { continue }
                ids.append(id)
            }
        }
        return ids
    }

    /// Finds all leftover files for the given bundle ID.
    public static func findLeftovers(
        bundleID: String,
        deleter: SafeFileDeleter = .shared
    ) -> [URL] {
        findLeftovers(
            bundleID: bundleID,
            home: FileManager.default.homeDirectoryForCurrentUser,
            deleter: deleter
        )
    }

    /// Home-injectable variant for testing against a temp HOME without
    /// touching the real `~/Library`.
    ///
    /// - Parameter embeddedBundleIDs: identifiers of helpers shipped inside
    ///   the app (see `embeddedBundleIDs(appURL:)`), matched exactly as well.
    public static func findLeftovers(
        bundleID: String,
        home: URL,
        deleter: SafeFileDeleter = .shared,
        embeddedBundleIDs: [String] = []
    ) -> [URL] {
        let ids = ([bundleID] + embeddedBundleIDs).filter(isUsableBundleID)
        guard !ids.isEmpty else { return [] }

        var results: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(url.path).inserted { results.append(url) }
        }
        let fm = FileManager.default

        // 1. ~/Library subdirectories — the entry's name must be the bundle ID.
        for subdir in librarySearchPaths {
            let dir = home.appendingPathComponent("Library/\(subdir)")
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            // "group.<id>" and Team-ID-prefixed names exist only here.
            let isGroupContainers = subdir == "Group Containers"
            for entry in entries where ids.contains(where: {
                matchesBundleID(entry.lastPathComponent, bundleID: $0, allowGroupForms: isGroupContainers)
            }) {
                add(entry)
            }
        }

        // 2. Preferences ByHost — `<bundleID>.<host UUID>.plist`.
        let byHostDir = home.appendingPathComponent("Library/Preferences/ByHost")
        if let byHostEntries = try? fm.contentsOfDirectory(
            at: byHostDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in byHostEntries where ids.contains(where: { matchesByHost(entry.lastPathComponent, bundleID: $0) }) {
                add(entry)
            }
        }

        // 3. The user's launch agents — `<bundleID>.plist` exactly.
        let userLaunch = home.appendingPathComponent("Library/LaunchAgents")
        if let entries = try? fm.contentsOfDirectory(
            at: userLaunch, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for entry in entries where ids.contains(where: { entry.lastPathComponent == "\($0).plist" }) {
                add(entry)
            }
        }

        // 4. Filter out protected paths.
        return results.filter { !PathProtection.shared.shouldProtect($0) }
    }

    /// System-level launch plists and privileged helpers that belong to the
    /// bundle ID. myKikau can't remove these (they need administrator
    /// rights), so they're surfaced for the user rather than planned.
    public static func systemLevelLeftovers(bundleID: String, embeddedBundleIDs: [String] = []) -> [URL] {
        let ids = ([bundleID] + embeddedBundleIDs).filter(isUsableBundleID)
        guard !ids.isEmpty else { return [] }
        var results: [URL] = []
        for path in launchPaths {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                if ids.contains(where: { name == $0 || name == "\($0).plist" }) {
                    results.append(entry)
                }
            }
        }
        return results
    }

    /// Builds a deletion plan for uninstalling an app + its leftovers.
    public static func uninstallPlan(
        app: AppInventory.AppInfo,
        deleter: SafeFileDeleter = .shared
    ) -> (appPlan: SafeFileDeleter.Plan, leftoverPlan: SafeFileDeleter.Plan) {
        uninstallPlan(
            app: app,
            home: FileManager.default.homeDirectoryForCurrentUser,
            deleter: deleter
        )
    }

    /// Home-injectable variant for testing.
    public static func uninstallPlan(
        app: AppInventory.AppInfo,
        home: URL,
        deleter: SafeFileDeleter = .shared
    ) -> (appPlan: SafeFileDeleter.Plan, leftoverPlan: SafeFileDeleter.Plan) {
        let appPlan = deleter.preview([app.url], category: .app)

        let leftovers: [URL]
        if !AppInventory.otherCopies(of: app).isEmpty {
            // Another copy of this app is installed elsewhere and uses the
            // same settings and data. They aren't leftovers.
            leftovers = []
        } else if let bundleID = app.bundleID {
            leftovers = findLeftovers(
                bundleID: bundleID,
                home: home,
                deleter: deleter,
                embeddedBundleIDs: embeddedBundleIDs(appURL: app.url)
            )
        } else {
            leftovers = []
        }
        let leftoverPlan = deleter.preview(leftovers, category: .leftover)
        return (appPlan, leftoverPlan)
    }

    /// Matches a file/directory name against a bundle ID: the ID itself, the
    /// ID plus a known file extension, or a group-container name wrapping it.
    ///
    /// - Parameter allowGroupForms: accept the `group.` / Team-ID wrappers.
    ///   Only `~/Library/Group Containers` uses them; anywhere else a name
    ///   like `ABCDEFGHIJ.<bundleID>` is just a different identifier.
    static func matchesBundleID(_ name: String, bundleID: String, allowGroupForms: Bool = true) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if isIDOrIDWithExtension(name, bundleID: bundleID) { return true }
        guard allowGroupForms else { return false }
        // Group containers: "group.<bundleID>", "<TeamID>.<bundleID>",
        // "<TeamID>.group.<bundleID>".
        var candidate = PathProtection.strippingTeamID(name)
        if candidate.hasPrefix("group.") { candidate.removeFirst("group.".count) }
        return candidate != name && candidate == bundleID
    }

    /// `<bundleID>.<host identifier>.plist`, where the host identifier is the
    /// hardware UUID (or the older 12-digit MAC form).
    static func matchesByHost(_ name: String, bundleID: String) -> Bool {
        let prefix = bundleID + "."
        let suffix = ".plist"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else {
            return false
        }
        let host = name.dropFirst(prefix.count).dropLast(suffix.count)
        return host.count >= 12 && host.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func isIDOrIDWithExtension(_ name: String, bundleID: String) -> Bool {
        if name == bundleID { return true }
        guard name.hasPrefix(bundleID + ".") else { return false }
        return leftoverExtensions.contains(String(name.dropFirst(bundleID.count + 1)))
    }
}
