import Foundation

/// Recursively scans a directory and aggregates file sizes.
/// Mirrors Mole's `cmd/analyze/scanner.go` disk traversal logic.
public enum DiskScanner {
    /// Represents a scanned entry (file or directory) with its size.
    public struct Entry: Identifiable, Hashable {
        public let id: String
        public let url: URL
        public let name: String
        public let sizeBytes: Int64
        public let isDirectory: Bool
        public let childCount: Int

        public init(url: URL, sizeBytes: Int64, isDirectory: Bool, childCount: Int = 0) {
            self.id = url.path
            self.url = url
            self.name = url.lastPathComponent
            self.sizeBytes = sizeBytes
            self.isDirectory = isDirectory
            self.childCount = childCount
        }
    }

    /// Default overview locations for the root scan (mirrors Mole's analyze).
    public static let overviewLocations: [String] = [
        "Home",
        "Library",
        "Applications",
        "Downloads",
        "Documents",
        "Desktop",
    ]

    /// Returns the URL for a named overview location.
    public static func overviewURL(for name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch name {
        case "Home": return home
        case "Applications": return URL(fileURLWithPath: "/Applications")
        default: return home.appendingPathComponent(name)
        }
    }

    /// Scans the immediate children of a directory and returns sorted entries.
    public static func scan(_ directory: URL) -> [Entry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [Entry] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = isDir ? directorySize(entry) : Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let childCount = isDir ? countChildren(entry) : 0
            results.append(Entry(url: entry, sizeBytes: size, isDirectory: isDir, childCount: childCount))
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Returns the total size of a directory (recursive).
    public static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                return size
            }
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Counts immediate children of a directory.
    public static func countChildren(_ url: URL) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.count
    }

    /// Finds the largest files within a directory tree (up to limit).
    public static func largeFiles(in directory: URL, limit: Int = 50) -> [Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [Entry] = []
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                files.append(Entry(url: fileURL, sizeBytes: Int64(values.fileSize ?? 0), isDirectory: false))
            }
        }
        return files.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit).map { $0 }
    }
}