import AppKit
import Foundation
import Core

/// Scans known cache/log/trash locations and builds a clean plan.
///
/// Rules every target list here follows:
/// - Only data an app can rebuild on its own. Profiles, databases, archives
///   and anything a user created are never targets.
/// - A shared container (`~/Library/Caches`, `~/Library/Logs`, the temp
///   folder) is never a target itself — its children are, one by one, so each
///   passes through `PathProtection` and can be reviewed individually.
/// - Caches of apps that are running, and `com.apple.*` caches, are left alone.
public enum CleanScanner {
    /// Categories of cleanable data.
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case userAppCache
        case browserCache
        case devTools
        case systemLogs
        case appSpecificCache
        case trash
        case recentItems

        public var id: String {
            rawValue
        }

        public var displayName: String {
            switch self {
            case .userAppCache: "User App Cache"
            case .browserCache: "Browser Cache"
            case .devTools: "Developer Tools"
            case .systemLogs: "Logs & Temporary Files"
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

        /// One line saying what the section holds and what removing it costs.
        public var explanation: String {
            switch self {
            case .userAppCache: "Caches that apps rebuild when they next need them. Running apps are skipped."
            case .browserCache: "Cached web content. Bookmarks, history, passwords and open tabs are not touched."
            case .devTools: "Build caches and package downloads. The next build or install re-downloads what it needs."
            case .systemLogs: "Your account's log files and temporary files untouched for three days."
            case .appSpecificCache: "Media and download caches for chat, music and meeting apps."
            case .trash: "Everything in the Trash. This is permanent."
            case .recentItems: "The Recent Items lists in the Apple menu and Open dialogs."
            }
        }
    }

    /// Temporary files modified more recently than this are assumed in use.
    static let temporaryFileMinimumAge: TimeInterval = 3 * 86400

    /// `~/Library/Caches` children owned by another section — excluded from
    /// "User App Cache" so nothing is counted (or queued for removal) twice.
    private static let cachesOwnedByOtherSections: Set<String> = [
        "Google", "Firefox", "Microsoft Edge", "BraveSoftware", "Arc", "Vivaldi", "com.operasoftware.Opera",
        "com.spotify.client", "com.getdropbox.dropbox", "us.zoom.xos",
        "go-build", "pip", "com.apple.dt.Xcode", "com.apple.helpd",
    ]

    /// Which app owns a cache that isn't named after its bundle ID. While
    /// that app is running, its cache is in use and is not a target.
    private static let cacheOwners: [(pathSuffix: String, bundleID: String)] = [
        ("Library/Caches/Google/Chrome", "com.google.Chrome"),
        ("Library/Containers/com.apple.Safari/Data/Library/Caches", "com.apple.Safari"),
        ("Library/Caches/Firefox", "org.mozilla.firefox"),
        ("Library/Caches/Microsoft Edge", "com.microsoft.edgemac"),
        ("Library/Caches/BraveSoftware/Brave-Browser", "com.brave.Browser"),
        ("Library/Caches/Arc", "company.thebrowser.Browser"),
        ("Library/Caches/Vivaldi", "com.vivaldi.Vivaldi"),
        ("Library/Caches/com.operasoftware.Opera", "com.operasoftware.Opera"),
        ("Library/Developer/Xcode/DerivedData", "com.apple.dt.Xcode"),
        ("Library/Developer/Xcode/iOS Device Logs", "com.apple.dt.Xcode"),
        ("Library/Caches/com.apple.dt.Xcode", "com.apple.dt.Xcode"),
        ("Library/Developer/CoreSimulator/Caches", "com.apple.iphonesimulator"),
        ("Library/Caches/com.spotify.client", "com.spotify.client"),
        ("Library/Caches/com.getdropbox.dropbox", "com.getdropbox.dropbox"),
        ("Library/Application Support/Slack/Cache", "com.tinyspeck.slackmacgap"),
        ("Library/Application Support/Slack/Code Cache", "com.tinyspeck.slackmacgap"),
        ("Library/Containers/com.microsoft.teams2/Data/Library/Caches", "com.microsoft.teams2"),
        ("Library/Application Support/discord/Cache", "com.hnc.Discord"),
        ("Library/Application Support/discord/Code Cache", "com.hnc.Discord"),
        ("Library/Caches/us.zoom.xos", "us.zoom.xos"),
        ("Library/Application Support/zoom.us/data/Cache", "us.zoom.xos"),
    ]

    /// Returns the candidate URLs for a given section.
    ///
    /// - Parameter home: The home directory to resolve paths against. Defaults to
    ///   the current user's home, so production callers are unaffected; tests pass a
    ///   temporary directory to avoid touching real `~/Library`.
    /// - Parameter runningBundleIDs: Bundle IDs of running apps, whose caches
    ///   are skipped. Defaults to what's actually running (or to nothing when
    ///   `home` is injected).
    public static func targets(
        for section: Section,
        home: URL? = nil,
        runningBundleIDs: Set<String>? = nil,
        now: Date = Date()
    ) -> [URL] {
        let resolvedHome = home ?? FileManager.default.homeDirectoryForCurrentUser
        // What's running only says something about the real home folder; an
        // injected one (tests) is judged on its contents alone.
        let running = runningBundleIDs ?? (home == nil ? currentRunningBundleIDs() : [])
        let inUse = Set(cacheOwners.filter { running.contains($0.bundleID) }
            .map { resolvedHome.appendingPathComponent($0.pathSuffix).path })
        return candidateTargets(for: section, home: home, running: running, now: now)
            .filter { !inUse.contains($0.path) }
    }

    /// Paths that are targets right now, across every section. A plan built
    /// earlier is checked against this before it's shown for confirmation —
    /// an app may have been opened, or a temp file touched, since the scan.
    public static func currentTargetPaths(home: URL? = nil, runningBundleIDs: Set<String>? = nil) -> Set<String> {
        Set(Section.allCases.flatMap { targets(for: $0, home: home, runningBundleIDs: runningBundleIDs) }.map(\.path))
    }

    /// `plan` without the items that have stopped being targets since it was built.
    public static func revalidated(
        _ plan: SafeFileDeleter.Plan,
        home: URL? = nil,
        runningBundleIDs: Set<String>? = nil
    ) -> SafeFileDeleter.Plan {
        let current = currentTargetPaths(home: home, runningBundleIDs: runningBundleIDs)
        return plan.keeping(Set(plan.items.map(\.id).filter(current.contains)))
    }

    private static func candidateTargets(
        for section: Section,
        home: URL?,
        running: Set<String>,
        now: Date
    ) -> [URL] {
        let injectedHome = home
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        switch section {
        case .userAppCache:
            return contents(of: home.appendingPathComponent("Library/Caches")).filter { entry in
                let name = entry.lastPathComponent
                if cachesOwnedByOtherSections.contains(name) {
                    return false
                }
                // System-managed; daemons hold these open.
                if name.hasPrefix("com.apple.") {
                    return false
                }
                // An app that's running is using its cache right now.
                if running.contains(name) {
                    return false
                }
                return true
            }

        case .browserCache:
            // Cache folders only. A browser's profile lives under Application
            // Support and holds bookmarks, saved logins and history — never a
            // target.
            return [
                home.appendingPathComponent("Library/Caches/Google/Chrome"),
                // Safari is sandboxed: its cache lives in its container.
                home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Caches"),
                home.appendingPathComponent("Library/Caches/Firefox"),
                // Chromium-based browsers cache under a product-name folder,
                // not their bundle ID.
                home.appendingPathComponent("Library/Caches/Microsoft Edge"),
                home.appendingPathComponent("Library/Caches/BraveSoftware/Brave-Browser"),
                home.appendingPathComponent("Library/Caches/Arc"),
                home.appendingPathComponent("Library/Caches/Vivaldi"),
                home.appendingPathComponent("Library/Caches/com.operasoftware.Opera"),
            ]

        case .devTools:
            // Re-creatable build output and download caches only. Xcode
            // Archives (shipped builds and their dSYMs) and the Maven local
            // repository (which can hold locally installed artefacts) are
            // deliberately not here.
            return [
                home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                home.appendingPathComponent("Library/Developer/Xcode/iOS Device Logs"),
                home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"),
                home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode"),
                home.appendingPathComponent(".npm/_cacache"),
                home.appendingPathComponent(".npm/_logs"),
                home.appendingPathComponent(".cache/node"),
                home.appendingPathComponent("Library/Caches/go-build"),
                home.appendingPathComponent(".cargo/registry/cache"),
                home.appendingPathComponent("Library/Caches/pip"),
                home.appendingPathComponent(".gradle/caches"),
            ]

        case .systemLogs:
            // Children of ~/Library/Logs — except myKikau's own operation log,
            // which is the audit trail of everything this app removes.
            let logs = contents(of: home.appendingPathComponent("Library/Logs"))
                .filter { $0.lastPathComponent != "myKikau" }
            // Real per-user temp files live under NSTemporaryDirectory() (a
            // $TMPDIR path like /var/folders/.../T/). Running apps keep files
            // open in there, so only take entries nobody has touched lately.
            let tempDir = injectedHome == nil
                ? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                : home.appendingPathComponent("private/tmp")
            let cutoff = now.addingTimeInterval(-temporaryFileMinimumAge)
            let staleTemp = contents(of: tempDir, keys: [.contentModificationDateKey]).filter { entry in
                guard let modified = latestModification(of: entry) else { return false }
                return modified < cutoff
            }
            return logs + [home.appendingPathComponent("Library/Caches/com.apple.helpd")] + staleTemp

        case .appSpecificCache:
            // Each path is where that vendor's app keeps its cache on macOS
            // today. Containers and Group Containers hold settings and data,
            // so only a `Caches` folder inside one is ever a target.
            return [
                home.appendingPathComponent("Library/Caches/com.spotify.client"),
                home.appendingPathComponent("Library/Caches/com.getdropbox.dropbox"),
                home.appendingPathComponent("Library/Application Support/Slack/Cache"),
                home.appendingPathComponent("Library/Application Support/Slack/Code Cache"),
                home.appendingPathComponent("Library/Containers/com.microsoft.teams2/Data/Library/Caches"),
                home.appendingPathComponent("Library/Application Support/discord/Cache"),
                home.appendingPathComponent("Library/Application Support/discord/Code Cache"),
                home.appendingPathComponent("Library/Caches/us.zoom.xos"),
                home.appendingPathComponent("Library/Application Support/zoom.us/data/Cache"),
            ]

        case .trash:
            // The individual *contents* of ~/.Trash, not the folder itself.
            // Emptying Trash has to permanently delete what's inside it — see
            // SafeFileDeleter.execute, which removes items that are already in
            // a Trash folder since they can't be "moved to the Trash" again.
            var trashFolders = [home.appendingPathComponent(".Trash")]
            if injectedHome == nil {
                // Each external volume keeps its own per-user Trash.
                let volumes = contents(of: URL(fileURLWithPath: "/Volumes"))
                trashFolders += volumes.map { $0.appendingPathComponent(".Trashes/\(getuid())") }
            }
            return trashFolders
                .flatMap { contents(of: $0, includeHidden: true) }
                .filter { $0.lastPathComponent != ".DS_Store" }

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
        let targets = targets(for: section, home: home)
        let category: SafeFileDeleter.Category = switch section {
        case .trash: .trash
        case .recentItems: .leftover
        case .systemLogs: .log
        default: .cache
        }
        return deleter.preview(targets, category: category)
    }

    /// Scans all sections, one after another, and returns a dictionary of
    /// plans. Stops early, returning what it has, if the surrounding task is
    /// cancelled.
    public static func scanAll(deleter: SafeFileDeleter = .shared, home: URL? = nil) -> [Section: SafeFileDeleter.Plan] {
        var plans: [Section: SafeFileDeleter.Plan] = [:]
        for section in Section.allCases {
            if Task.isCancelled {
                break
            }
            plans[section] = scan(section, deleter: deleter, home: home)
        }
        return plans
    }

    /// Scans all sections concurrently. `onSection` is called as each one
    /// finishes, for progress reporting. Child tasks inherit cancellation, so
    /// cancelling the caller stops the directory walks.
    public static func scanAllConcurrently(
        deleter: SafeFileDeleter = .shared,
        home: URL? = nil,
        onSection: (@Sendable (Section) -> Void)? = nil
    ) async -> [Section: SafeFileDeleter.Plan] {
        await withTaskGroup(of: (Section, SafeFileDeleter.Plan).self) { group in
            for section in Section.allCases {
                group.addTask { (section, scan(section, deleter: deleter, home: home)) }
            }
            var plans: [Section: SafeFileDeleter.Plan] = [:]
            for await (section, plan) in group {
                plans[section] = plan
                onSection?(section)
            }
            return plans
        }
    }

    /// When an entry was last touched. A folder's own date doesn't change
    /// when a file inside it is rewritten, so for a folder this is the newest
    /// date among the folder and the entries directly inside it.
    private static func latestModification(of entry: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        guard let values = try? entry.resourceValues(forKeys: keys),
              var latest = values.contentModificationDate else { return nil }
        if values.isDirectory == true {
            for child in contents(of: entry, keys: [.contentModificationDateKey], includeHidden: true) {
                if let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date > latest
                {
                    latest = date
                }
            }
        }
        return latest
    }

    private static func currentRunningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Returns the immediate contents of a directory as URLs.
    private static func contents(
        of dir: URL,
        keys: [URLResourceKey]? = nil,
        includeHidden: Bool = false
    ) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: includeHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
    }
}
