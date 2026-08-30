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
        /// Whether tapping this entry should drill into it. Real directories are
        /// navigable; synthetic rows (Free space, the "macOS System" remainder,
        /// an aggregated "Hidden Items" bucket) are not.
        public let isNavigable: Bool

        public init(url: URL, sizeBytes: Int64, isDirectory: Bool, childCount: Int = 0, isNavigable: Bool? = nil) {
            self.id = url.path
            self.url = url
            self.name = url.lastPathComponent
            self.sizeBytes = sizeBytes
            self.isDirectory = isDirectory
            self.childCount = childCount
            self.isNavigable = isNavigable ?? isDirectory
        }

        /// A non-navigable, computed row (Free space, "macOS System", "Hidden Items").
        init(syntheticName name: String, parent: URL, sizeBytes: Int64, childCount: Int = 0) {
            self.id = "synthetic://\(name)"
            self.url = parent.appendingPathComponent(name)
            self.name = name
            self.sizeBytes = sizeBytes
            self.isDirectory = false
            self.childCount = childCount
            self.isNavigable = false
        }
    }

    /// Describes the startup volume's capacity for the whole-disk overview.
    public struct VolumeInfo: Hashable {
        public let name: String
        public let totalBytes: Int64
        /// Free space including purgeable — matches Finder's "Available".
        public let freeBytes: Int64
    }

    /// Real top-level directories worth measuring for the whole-disk overview.
    /// Each lives on the writable data volume; everything on the read-only
    /// system volume, plus anything not listed here (notably `/private/var`,
    /// which is system-managed, permission-noisy and slow to walk), is folded
    /// into a computed "macOS System" remainder so the chart still sums to
    /// total capacity. Deliberately excludes `/System/Volumes/Data` (a firmlink
    /// that would double-count the whole data volume) and `/Volumes` (other
    /// mounts).
    public static let overviewRoots: [String] = [
        "/Applications",
        "/Users",
        "/Library",
        "/opt",
        "/usr/local",
    ]

    /// Reads the startup volume's name and capacity, or `nil` if unavailable.
    public static func startupVolumeInfo() -> VolumeInfo? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return nil }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        guard total > 0 else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            name: values.volumeName ?? "Macintosh HD",
            totalBytes: total,
            freeBytes: max(0, free)
        )
    }

    /// Builds the whole-disk overview: the measured `overviewRoots`, a computed
    /// "macOS System" remainder, and a "Free" row, so the set sums to the
    /// startup volume's total capacity. Every real directory keeps its URL so
    /// the existing drill-down (`scan(_:)`) works on it unchanged.
    public static func volumeOverview() -> [Entry] {
        guard let info = startupVolumeInfo() else {
            // No capacity info — degrade to a plain listing of "/".
            return scan(URL(fileURLWithPath: "/"))
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/")
        let roots = overviewRoots.filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        // Walk the roots concurrently — `/Users` and `/Library` alone are large
        // enough that doing them serially makes the overview feel broken.
        var sizes = [Int64](repeating: 0, count: roots.count)
        sizes.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: roots.count) { index in
                buffer[index] = directorySize(URL(fileURLWithPath: roots[index]))
            }
        }
        var measured: [Entry] = []
        var accounted: Int64 = 0
        for (index, path) in roots.enumerated() where sizes[index] > 0 {
            let url = URL(fileURLWithPath: path)
            accounted += sizes[index]
            measured.append(Entry(
                url: url,
                sizeBytes: sizes[index],
                isDirectory: true,
                childCount: countChildren(url)
            ))
        }
        measured.sort { $0.sizeBytes > $1.sizeBytes }

        let used = max(0, info.totalBytes - info.freeBytes)
        let systemRemainder = max(0, used - accounted)
        var results = measured
        if systemRemainder > 0 {
            results.append(Entry(
                syntheticName: "macOS System",
                parent: root,
                sizeBytes: systemRemainder
            ))
        }
        results.append(Entry(syntheticName: "Free", parent: root, sizeBytes: info.freeBytes))
        return results
    }

    /// Scans the immediate children of a directory and returns sorted entries.
    ///
    /// Deliberately does NOT pass `.skipsHiddenFiles` to the enumerator: macOS
    /// flags `~/Library` hidden via `chflags UF_HIDDEN` (it has no dot prefix),
    /// so that option was silently dropping Library — often the single largest
    /// item in a home directory — from every scan, which is why totals like
    /// "Home: 263GB" were undercounting real disk usage.
    ///
    /// `includeHidden` controls only dot-prefixed entries (`.cache`, `.docker`,
    /// `.npm`, `.Trash`, …). When `true` (the default — a disk analyser exists
    /// to surface space hogs, and dot-folders are frequently the biggest) each
    /// one is a normal, drillable row. When `false` they collapse into a single
    /// non-navigable "Hidden Items" total. `~/Library` and other chflags-hidden
    /// entries without a dot prefix are always shown either way.
    public static func scan(_ directory: URL, includeHidden: Bool = true) -> [Entry] {
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
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if entry.lastPathComponent.hasPrefix(".") && !includeHidden {
                hiddenTotal += isDir ? directorySize(entry) : allocatedSize(entry)
                hiddenCount += 1
                continue
            }
            let size = isDir ? directorySize(entry) : allocatedSize(entry)
            let childCount = isDir ? countChildren(entry) : 0
            results.append(Entry(url: entry, sizeBytes: size, isDirectory: isDir, childCount: childCount))
        }
        if hiddenTotal > 0 {
            results.append(Entry(
                syntheticName: "Hidden Items",
                parent: directory,
                sizeBytes: hiddenTotal,
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

    /// Counts immediate children of a directory. `includeHidden` mirrors
    /// `scan(_:includeHidden:)` so the "N items" label matches the rows shown.
    public static func countChildren(_ url: URL, includeHidden: Bool = true) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: []
        ) else { return 0 }
        if includeHidden { return entries.count }
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
