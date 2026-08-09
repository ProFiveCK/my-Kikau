import Foundation

/// Recursively scans a directory and aggregates file sizes.
/// Mirrors Mole's `cmd/analyze/scanner.go` disk traversal logic.
public enum DiskScanner {
    /// Represents a scanned entry (file or directory) with its allocated disk size.
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
    ///
    /// Deliberately does NOT pass `.skipsHiddenFiles` to the enumerator: macOS
    /// flags `~/Library` hidden via `chflags UF_HIDDEN` (it has no dot prefix),
    /// so that option was silently dropping Library — often the single largest
    /// item in a home directory — from every scan, which is why totals like
    /// "Home: 263GB" were undercounting real disk usage. We instead filter out
    /// only dot-prefixed entries (.Trash, .ssh, .zshrc, etc.) ourselves, which
    /// keeps the listing free of clutter while still surfacing Library.
    public static func scan(_ directory: URL) -> [Entry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) else {
            return []
        }
        var results: [Entry] = []
        var hiddenTotal: Int64 = 0
        var hiddenCount = 0
        for entry in entries {
            if entry.lastPathComponent.hasPrefix(".") {
                hiddenTotal += directorySize(entry)
                hiddenCount += 1
                continue
            }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = isDir ? directorySize(entry) : allocatedSize(entry)
            let childCount = isDir ? countChildren(entry) : 0
            results.append(Entry(url: entry, sizeBytes: size, isDirectory: isDir, childCount: childCount))
        }
        if hiddenTotal > 0 {
            results.append(Entry(
                url: directory.appendingPathComponent("Hidden Items"),
                sizeBytes: hiddenTotal,
                isDirectory: false,
                childCount: hiddenCount
            ))
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Returns the total allocated size of a directory (recursive).
    ///
    /// Includes hidden files/folders in the sum — a folder's real disk usage
    /// doesn't stop at dotfiles or chflags-hidden entries. Uses allocated-size
    /// resource keys rather than logical file length so APFS sparse files and
    /// clones do not make the chart claim more physical storage than exists.
    public static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return allocatedSize(url)
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Best available allocated size for a file URL, falling back to logical size.
    public static func allocatedSize(_ url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey]) {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            return size
        }
        return 0
    }

    /// Counts immediate children of a directory (matches `scan`'s dot-prefix filtering).
    public static func countChildren(_ url: URL) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: []
        ) else { return 0 }
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }.count
    }

    /// Finds the largest files within a directory tree (up to limit).
    /// Includes hidden files — large caches often live under dotfile paths
    /// (e.g. `.cache`, `.npm`) and shouldn't be invisible to this scan.
    public static func largeFiles(in directory: URL, limit: Int = 50) -> [Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return [] }
        var files: [Entry] = []
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                files.append(Entry(
                    url: fileURL,
                    sizeBytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0),
                    isDirectory: false
                ))
            }
        }
        return files.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit).map { $0 }
    }
}
