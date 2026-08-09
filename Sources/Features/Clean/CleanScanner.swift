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
        let injectedHome = home
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
                // Safari — sandboxed since Safari 13 (all currently supported
                // macOS versions), so its real cache lives under its
                // Container, not the old unsandboxed ~/Library/Caches path
                // (which no longer exists and made this entry permanently
                // report "missing").
                home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Caches"),
                home.appendingPathComponent("Library/Safari/CloudTabs.db"),
                // Firefox
                home.appendingPathComponent("Library/Caches/Firefox"),
                home.appendingPathComponent("Library/Application Support/Firefox/Profiles"),
                // Edge — Chromium-based browsers don't cache under their
                // bundle ID like sandboxed apps do; they use their own
                // product-name folder. Was "com.microsoft.edgemac", which
                // never existed.
                home.appendingPathComponent("Library/Caches/Microsoft Edge"),
                // Brave — same story: real cache folder is nested under
                // BraveSoftware/Brave-Browser, not the bundle ID directly.
                home.appendingPathComponent("Library/Caches/BraveSoftware/Brave-Browser"),
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
                // Was `home.appendingPathComponent("private/tmp")` — that
                // resolves to ~/private/tmp, which never exists (it's a
                // home-relative typo for the real system temp dir). Real
                // per-user temp files live under NSTemporaryDirectory()
                // (a $TMPDIR path like /var/folders/.../T/), which is safe
                // and meaningful for a normal user process to clear.
                injectedHome == nil
                    ? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    : home.appendingPathComponent("private/tmp"),
            ]

        case .appSpecificCache:
            // Verified each of these against how that vendor's app actually
            // stores its cache on macOS today — several assumptions here
            // were wrong, and not in the same way:
            //   Spotify -> real cache: ~/Library/Caches/com.spotify.client (unchanged, correct)
            //   Dropbox -> was the truncated "com.dropbox"; real bundle ID
            //              is com.getdropbox.dropbox
            //   Slack   -> Electron app; doesn't cache under ~/Library/Caches
            //              at all. Real cache: ~/Library/Application Support/Slack/Cache
            //   Discord -> same story, real cache: ~/Library/Application Support/discord/Cache
            //   Teams   -> "new Teams" is sandboxed; real data is under its
            //              Container and Group Container, not ~/Library/Caches
            //   Zoom    -> the one exception that *does* use ~/Library/Caches
            //              directly, but under its real bundle ID us.zoom.xos
            //              (was the wrong com.zoom.us), plus its separate
            //              Application Support data folder
            //   Safari  -> handled under .browserCache, not here
            return [
                home.appendingPathComponent("Library/Caches/com.spotify.client"),
                home.appendingPathComponent("Library/Caches/com.getdropbox.dropbox"),
                home.appendingPathComponent("Library/Application Support/Slack/Cache"),
                home.appendingPathComponent("Library/Containers/com.microsoft.teams2/Data/Library/Caches"),
                home.appendingPathComponent("Library/Group Containers/UBF8T346G9.com.microsoft.teams"),
                home.appendingPathComponent("Library/Application Support/discord/Cache"),
                home.appendingPathComponent("Library/Caches/us.zoom.xos"),
                home.appendingPathComponent("Library/Application Support/zoom.us/data/Cache"),
            ]

        case .trash:
            // The individual *contents* of ~/.Trash, not the folder itself.
            // Emptying Trash has to permanently delete what's inside it — see
            // SafeFileDeleter.execute, which forces .trash-category items to
            // .permanent regardless of the caller's requested mode, since
            // "move ~/.Trash to the Trash" is meaningless (and macOS rejects it).
            return contents(of: home.appendingPathComponent(".Trash"))

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
