import Foundation
import Core

/// Inventories installed applications from /Applications and ~/Applications.
/// Mirrors Mole's `bin/uninstall.sh` app inventory logic.
public enum AppInventory {
    /// Represents an installed application.
    public struct AppInfo: Identifiable, Hashable {
        public let id: String          // bundle ID or path
        public let url: URL
        public let name: String
        public let bundleID: String?
        public let version: String?
        public let sizeBytes: Int64
        public let lastModified: Date?
        public let lastUsed: Date?

        public init(
            url: URL,
            name: String,
            bundleID: String?,
            version: String?,
            sizeBytes: Int64,
            lastModified: Date?,
            lastUsed: Date? = nil
        ) {
            self.id = bundleID ?? url.path
            self.url = url
            self.name = name
            self.bundleID = bundleID
            self.version = version
            self.sizeBytes = sizeBytes
            self.lastModified = lastModified
            self.lastUsed = lastUsed
        }
    }

    /// Scans standard application directories for .app bundles.
    public static func scan(deleter: SafeFileDeleter = .shared) -> [AppInfo] {
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var apps: [AppInfo] = []
        for dir in appDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries where entry.pathExtension == "app" {
                if let app = inspect(entry, deleter: deleter) {
                    apps.append(app)
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Inspects a single .app bundle and extracts metadata.
    public static func inspect(_ appURL: URL, deleter: SafeFileDeleter = .shared) -> AppInfo? {
        let bundle = Bundle(path: appURL.path)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let size = deleter.directorySize(appURL)
        let lastModified = try? appURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let lastUsed = metadataDate(appURL, key: "kMDItemLastUsedDate")

        return AppInfo(
            url: appURL, name: name, bundleID: bundleID,
            version: version, sizeBytes: size, lastModified: lastModified, lastUsed: lastUsed
        )
    }

    /// Returns true if the app is protected from uninstallation.
    public static func isProtected(_ app: AppInfo) -> Bool {
        guard let bundleID = app.bundleID else { return false }
        return PathProtection.shared.isSystemCriticalBundle(bundleID)
    }

    private static func metadataDate(_ url: URL, key: String) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-raw", "-name", key, url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "(null)" else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: raw)
    }
}
