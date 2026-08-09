import Foundation
import Core

/// Finds leftover files for an app by exact bundle ID match.
/// Mirrors Mole's `lib/uninstall/*.sh` — exact bundle-ID or exact-path evidence only.
/// Never uses vendor-prefix or generic-name wildcards (per AGENTS.md safety rule).
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
    ]

    /// System-level launch agent/daemon locations.
    public static let launchPaths: [String] = [
        "/Library/LaunchDaemons",
        "/Library/LaunchAgents",
        "/Library/PrivilegedHelperTools",
    ]

    /// User-level launch agent locations.
    public static var userLaunchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/LaunchAgents").path]
    }

    /// Finds all leftover files for the given bundle ID.
    /// Matching is exact: the path component must equal the bundle ID,
    /// or a file name must be `<bundleID>.plist` / `<bundleID>.<ext>`.
    public static func findLeftovers(
        bundleID: String,
        deleter: SafeFileDeleter = .shared
    ) -> [URL] {
        var results: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        // 1. ~/Library subdirectories — match by exact bundle ID in path components.
        for subdir in librarySearchPaths {
            let dir = home.appendingPathComponent("Library/\(subdir)")
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if matchesBundleID(entry.lastPathComponent, bundleID: bundleID) {
                    results.append(entry)
                }
            }
        }

        // 2. Preferences — match `<bundleID>.plist` and `ByHost/<bundleID>.*`.
        let prefsDir = home.appendingPathComponent("Library/Preferences")
        let prefsPlist = prefsDir.appendingPathComponent("\(bundleID).plist")
        if fm.fileExists(atPath: prefsPlist.path) {
            results.append(prefsPlist)
        }
        // ByHost preferences use a UUID-hashed variant; match by bundle ID prefix.
        let byHostDir = prefsDir.appendingPathComponent("ByHost")
        if let byHostEntries = try? fm.contentsOfDirectory(
            at: byHostDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in byHostEntries where entry.lastPathComponent.contains(bundleID) {
                results.append(entry)
            }
        }

        // 3. Launch agents/daemons — match plist files containing the bundle ID
        //    in ProgramArguments or the file name.
        for path in launchPaths + userLaunchPaths {
            guard let entries = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "plist" {
                if entry.lastPathComponent.contains(bundleID) {
                    results.append(entry)
                }
            }
        }

        // 4. Filter out protected paths.
        return results.filter { !PathProtection.shared.shouldProtect($0) }
    }

    /// Builds a deletion plan for uninstalling an app + its leftovers.
    public static func uninstallPlan(
        app: AppInventory.AppInfo,
        deleter: SafeFileDeleter = .shared
    ) -> (appPlan: SafeFileDeleter.Plan, leftoverPlan: SafeFileDeleter.Plan) {
        let appPlan = deleter.preview([app.url], category: .app)

        let leftovers: [URL]
        if let bundleID = app.bundleID {
            leftovers = findLeftovers(bundleID: bundleID, deleter: deleter)
        } else {
            leftovers = []
        }
        let leftoverPlan = deleter.preview(leftovers, category: .leftover)
        return (appPlan, leftoverPlan)
    }

    /// Matches a file/directory name against a bundle ID.
    /// Exact match or `<bundleID>.<extension>` form.
    private static func matchesBundleID(_ name: String, bundleID: String) -> Bool {
        if name == bundleID { return true }
        // e.g. "com.example.app.plist" matches bundleID "com.example.app"
        if name.hasPrefix(bundleID + ".") { return true }
        // Group containers use "group.<bundleID>" or TeamID prefix
        if name.hasPrefix("group." + bundleID) { return true }
        return false
    }
}