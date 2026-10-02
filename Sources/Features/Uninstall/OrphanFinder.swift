import AppKit
import Foundation
import Core

/// Finds what uninstalled apps left behind: `~/Library` entries named after
/// a bundle ID that no longer belongs to any app on this Mac.
///
/// The evidence here is weaker than for an uninstall (there is no app to
/// read the bundle ID from), so every rule errs toward leaving things alone:
/// - the name must be a full reverse-DNS identifier (three or more labels),
///   optionally with a known leftover extension;
/// - never `com.apple.*`, never anything `PathProtection` guards;
/// - no installed app, embedded helper, or app registered with Launch
///   Services may have that identifier — or an identifier it extends;
/// - untouched for at least `minimumAge`;
/// - containers are excluded entirely (macOS manages them).
///
/// Results are suggestions for the user to tick, never pre-selected.
public enum OrphanFinder {
    public struct Orphan: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        public let url: URL
        public let bundleID: String
        public let lastModified: Date
    }

    /// `~/Library` folders searched. Containers and Group Containers are
    /// deliberately absent.
    static let searchSubdirectories = [
        "Application Support", "Caches", "Preferences", "Saved Application State",
        "HTTPStorages", "WebKit", "Logs"
    ]

    public static let minimumAge: TimeInterval = 90 * 86_400

    /// - Parameters:
    ///   - installedBundleIDs: identifiers of installed apps and their
    ///     embedded helpers. Defaults to what's on disk.
    ///   - isRegistered: whether Launch Services knows an app with this
    ///     identifier (catches apps installed outside the standard folders).
    public static func find(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        installedBundleIDs: Set<String>? = nil,
        isRegistered: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        now: Date = Date()
    ) -> [Orphan] {
        let installed = installedBundleIDs ?? allInstalledBundleIDs()
        let cutoff = now.addingTimeInterval(-minimumAge)
        let fm = FileManager.default
        var orphans: [Orphan] = []

        for subdirectory in searchSubdirectories {
            if Task.isCancelled { break }
            let dir = home.appendingPathComponent("Library/\(subdirectory)")
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                guard let bundleID = bundleID(fromEntryName: entry.lastPathComponent),
                      isOrphanCandidate(bundleID, installed: installed),
                      !isRegistered(bundleID),
                      !PathProtection.shared.shouldProtect(entry),
                      let modified = latestModification(of: entry), modified < cutoff else { continue }
                orphans.append(Orphan(url: entry, bundleID: bundleID, lastModified: modified))
            }
        }
        return orphans.sorted { $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending }
    }

    public static func plan(for orphans: [Orphan], deleter: SafeFileDeleter = .shared) -> SafeFileDeleter.Plan {
        deleter.preview(orphans.map(\.url), category: .leftover)
    }

    /// The bundle ID an entry is named after: the name itself, or the name
    /// minus one known leftover extension. `nil` if it isn't shaped like one.
    static func bundleID(fromEntryName name: String) -> String? {
        var candidate = name
        for ext in LeftoverFinder.leftoverExtensions.sorted(by: { $0.count > $1.count })
        where candidate.hasSuffix("." + ext) {
            candidate.removeLast(ext.count + 1)
            break
        }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3,
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              // A real identifier starts with a top-level domain, not a version number.
              labels[0].allSatisfy(\.isLetter), labels[0].count >= 2
        else { return nil }
        return candidate
    }

    static func isOrphanCandidate(_ bundleID: String, installed: Set<String>) -> Bool {
        guard LeftoverFinder.isUsableBundleID(bundleID), !bundleID.lowercased().hasPrefix("com.apple.") else {
            return false
        }
        let lowered = bundleID.lowercased()
        for id in installed {
            let other = id.lowercased()
            // Installed, or a component of something installed (an app's
            // helper, plug-in or per-feature store).
            if lowered == other || lowered.hasPrefix(other + ".") { return false }
        }
        return true
    }

    /// Identifiers of every installed app plus the helpers inside each one.
    static func allInstalledBundleIDs() -> Set<String> {
        var ids = Set<String>()
        for app in AppInventory.appBundleURLs() {
            if let id = Bundle(url: app)?.bundleIdentifier { ids.insert(id) }
            ids.formUnion(LeftoverFinder.embeddedBundleIDs(appURL: app))
        }
        for running in NSWorkspace.shared.runningApplications {
            if let id = running.bundleIdentifier { ids.insert(id) }
        }
        return ids
    }

    /// Newest date among the entry and, for a folder, the entries directly in it.
    private static func latestModification(of entry: URL) -> Date? {
        guard var latest = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        if let children = try? FileManager.default.contentsOfDirectory(
            at: entry, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) {
            for child in children {
                if let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date > latest {
                    latest = date
                }
            }
        }
        return latest
    }
}
