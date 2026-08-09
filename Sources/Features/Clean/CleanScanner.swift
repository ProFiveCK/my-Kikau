import Foundation
import Core

/// Scans known cache/log/trash locations and builds a clean plan.
/// Target paths ported from Mole's `lib/clean/{caches,user,dev,system,apps}.sh`.
public enum CleanScanner {
    /// Categories of cleanable data.
    public enum Section: String, CaseIterable, Identifiable {
        case userAppCache
        case browserCache
        case devTools
        case systemLogs
        case appSpecificCache
        case trash
        case recentItems

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .userAppCache: "User App Cache"
            case .browserCache: "Browser Cache"
            case .devTools: "Developer Tools"
            case .systemLogs: "System Logs & Temp"
            case .appSpecificCache: "App-Specific Cache"
            case .trash: "Trash"
            case .recentItems: "Recent Items"
            }
        }

        public var icon: String {
            switch self {
            case .userAppCache: "internaldrive"
            case .browserCache: "network"
            case .devTools: "hammer"
            case .systemLogs: "doc.text"
            case .appSpecificCache: "app.dashed"
            case .trash: "trash"
            case .recentItems: "clock"
            }
        }
    }

    /// Returns the candidate URLs for a given section.
    ///
    /// - Parameter home: The home directory to resolve paths against. Defaults to
    ///   the current user's home, so production callers are unaffected; tests pass a
    ///   temporary directory to avoid touching real `~/Library`.
    public static func targets(for section: Section, home: URL? = nil) -> [URL] {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        switch section {
        case .userAppCache:
            // ~/Library/Caches/* (user app caches)
            return contents(of: home.appendingPathComponent("Library/Caches"))

        case .browserCache:
            return [
                // Chrome
                home.appendingPathComponent("Library/Caches/Google/Chrome"),
                home.appendingPathComponent("Library/Application Support/Google/Chrome/Service Worker"),
                // Safari
                home.appendingPathComponent("Library/Caches/com.apple.Safari"),
                home.appendingPathComponent("Library/Safari/CloudTabs.db"),
                // Firefox
                home.appendingPathComponent("Library/Caches/Firefox"),
                home.appendingPathComponent("Library/Application Support/Firefox/Profiles"),
                // Edge
                home.appendingPathComponent("Library/Caches/com.microsoft.edgemac"),
                // Brave
                home.appendingPathComponent("Library/Caches/com.brave.Browser"),
            ]

        case .devTools:
            return [
                // Xcode
                home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                home.appendingPathComponent("Library/Developer/Xcode/Archives"),
                home.appendingPathComponent("Library/Developer/Xcode/iOS Device Logs"),
                home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"),
                // Node.js / npm
                home.appendingPathComponent(".npm"),
                home.appendingPathComponent(".cache/node"),
                home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode"),
                // Go
                home.appendingPathComponent("Library/Caches/go-build"),
                // Cargo (Rust)
                home.appendingPathComponent(".cargo/registry/cache"),
                home.appendingPathComponent(".cargo/registry/git"),
                // pip / Python
                home.appendingPathComponent("Library/Caches/pip"),
                // Gradle
                home.appendingPathComponent(".gradle/caches"),
                // Maven
                home.appendingPathComponent(".m2/repository"),
            ]

        case .systemLogs:
            return [
                home.appendingPathComponent("Library/Logs"),
                home.appendingPathComponent("Library/Caches/com.apple.helpd"),
                home.appendingPathComponent("private/tmp"),
            ]

        case .appSpecificCache:
            return [
                home.appendingPathComponent("Library/Caches/com.spotify.client"),
                home.appendingPathComponent("Library/Caches/com.dropbox"),
                home.appendingPathComponent("Library/Caches/com.tinyspeck.chat.slack"),
                home.appendingPathComponent("Library/Caches/com.microsoft.teams"),
                home.appendingPathComponent("Library/Caches/com.discord"),
                home.appendingPathComponent("Library/Caches/com.zoom.us"),
            ]

        case .trash:
            return [home.appendingPathComponent(".Trash")]

        case .recentItems:
            let sharedDir = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
            return [
                sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentApplications.sfl2"),
                sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments.sfl2"),
                sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentServers.sfl2"),
                sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentHosts.sfl2"),
                home.appendingPathComponent("Library/Preferences/com.apple.recentitems.plist"),
            ]
        }
    }

    /// Scans a section and returns a deletion plan.
    public static func scan(_ section: Section, deleter: SafeFileDeleter = .shared, home: URL? = nil) -> SafeFileDeleter.Plan {
        let targets = self.targets(for: section, home: home)
        let category: SafeFileDeleter.Category
        switch section {
        case .trash: category = .trash
        case .recentItems: category = .leftover
        default: category = .cache
        }
        return deleter.preview(targets, category: category)
    }

    /// Scans all sections and returns a dictionary of plans.
    public static func scanAll(deleter: SafeFileDeleter = .shared, home: URL? = nil) -> [Section: SafeFileDeleter.Plan] {
        var plans: [Section: SafeFileDeleter.Plan] = [:]
        for section in Section.allCases {
            plans[section] = scan(section, deleter: deleter, home: home)
        }
        return plans
    }

    /// Returns the immediate contents of a directory as URLs.
    private static func contents(of dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
    }
}