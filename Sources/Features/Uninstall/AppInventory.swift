import AppKit
import CoreServices
import Foundation
import Core

/// Inventories installed applications from /Applications and ~/Applications.
public enum AppInventory {
    /// Represents an installed application.
    public struct AppInfo: Identifiable, Hashable, Sendable {
        /// The bundle's path — unique even when two copies of the same app
        /// (same bundle ID) are installed in different places.
        public let id: String
        public let url: URL
        public let name: String
        public let bundleID: String?
        public let version: String?
        public let sizeBytes: Int64
        public let lastModified: Date?
        public let lastUsed: Date?
        /// The bundle is owned by another user (root, for App Store and most
        /// package installs). Moving it to the Trash needs administrator
        /// rights that myKikau doesn't have.
        public let requiresAdministrator: Bool
        public let isAppStore: Bool

        public init(
            url: URL,
            name: String,
            bundleID: String?,
            version: String?,
            sizeBytes: Int64,
            lastModified: Date?,
            lastUsed: Date? = nil,
            requiresAdministrator: Bool = false,
            isAppStore: Bool = false
        ) {
            self.id = url.path
            self.url = url
            self.name = name
            self.bundleID = bundleID
            self.version = version
            self.sizeBytes = sizeBytes
            self.lastModified = lastModified
            self.lastUsed = lastUsed
            self.requiresAdministrator = requiresAdministrator
            self.isAppStore = isAppStore
        }
    }

    /// Scans standard application directories for .app bundles.
    ///
    /// Descends one level into plain (non-`.app`) subfolders of each root —
    /// vendor installers commonly group related apps under a folder instead
    /// of dropping them straight into `/Applications` (e.g. Adobe Acrobat
    /// installs to `/Applications/Adobe Acrobat DC/Adobe Acrobat.app`, and
    /// OpenVPN Connect follows the same pattern). A plain top-level listing
    /// only ever saw the container folder — never a `.app` itself, so it was
    /// silently skipped — which under-reported the app inventory without any
    /// error to signal it. Doesn't recurse further than one level: that
    /// covers the vendor-folder pattern without turning this into a full
    /// filesystem walk (an `.app` bundle inside another `.app` — a plugin or
    /// helper — is intentionally left alone; that's the outer app's business).
    ///
    /// Bundles are measured concurrently; sizing is the slow part.
    public static func scan(deleter: SafeFileDeleter = .shared) -> [AppInfo] {
        let bundles = appBundleURLs()
        return concurrentMap(bundles) { inspect($0, deleter: deleter) }
            .compactMap { $0 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every `.app` bundle in the standard locations, without measuring them.
    public static func appBundleURLs() -> [URL] {
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var bundles: [URL] = []
        for dir in appDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries {
                if entry.pathExtension == "app" {
                    bundles.append(entry)
                    continue
                }
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                guard let nested = try? FileManager.default.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                bundles.append(contentsOf: nested.filter { $0.pathExtension == "app" })
            }
        }
        return bundles
    }

    /// Other installed bundles with the same bundle ID as `app` (a second
    /// copy in `~/Applications`, say). They share its settings, data, launch
    /// agents and login item — so none of those belong to this copy alone.
    public static func otherCopies(of app: AppInfo, among bundles: [URL]? = nil) -> [URL] {
        guard let bundleID = app.bundleID else { return [] }
        let this = app.url.standardizedFileURL
        return (bundles ?? appBundleURLs()).filter { url in
            url.standardizedFileURL != this && Bundle(url: url)?.bundleIdentifier == bundleID
        }
    }

    /// Inspects a single .app bundle and extracts metadata.
    public static func inspect(_ appURL: URL, deleter: SafeFileDeleter = .shared) -> AppInfo? {
        let bundle = Bundle(path: appURL.path)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let size = deleter.directorySize(appURL)
        let lastModified = try? appURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let ownerID = (try? FileManager.default.attributesOfItem(atPath: appURL.path))?[.ownerAccountID] as? NSNumber
        let isAppStore = FileManager.default.fileExists(
            atPath: appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path
        )

        return AppInfo(
            url: appURL, name: name, bundleID: bundleID,
            version: version, sizeBytes: size, lastModified: lastModified,
            lastUsed: lastUsedDate(appURL),
            requiresAdministrator: ownerID.map { $0.uint32Value != getuid() } ?? false,
            isAppStore: isAppStore
        )
    }

    /// Returns true if the app is protected from uninstallation: a critical
    /// system app, a security or device-management agent, or myKikau itself.
    public static func isProtected(_ app: AppInfo) -> Bool {
        if app.url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return true }
        guard let bundleID = app.bundleID else { return false }
        let protection = PathProtection.shared
        return protection.isSystemCriticalBundle(bundleID) || protection.isEndpointSecurityBundle(bundleID)
    }

    /// Why an app is protected, for display. `nil` when it isn't.
    public static func protectionReason(_ app: AppInfo) -> String? {
        if app.url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            return "This is myKikau"
        }
        guard let bundleID = app.bundleID else { return nil }
        let protection = PathProtection.shared
        if protection.isEndpointSecurityBundle(bundleID) { return "Security or device-management software" }
        if protection.isSystemCriticalBundle(bundleID) { return "Part of macOS" }
        return nil
    }

    /// True if the app (by bundle ID or path) is currently running.
    public static func isRunning(_ app: AppInfo) -> Bool {
        !runningInstances(of: app).isEmpty
    }

    public static func runningInstances(of app: AppInfo) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { running in
            if let bundleURL = running.bundleURL, bundleURL.standardizedFileURL == app.url.standardizedFileURL {
                return true
            }
            return false
        }
    }

    /// Spotlight's "last used" date, read in-process through the metadata
    /// framework (no `mdls` subprocess per app).
    private static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
