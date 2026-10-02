import Foundation
import Core

/// Recursively scans a directory and aggregates file sizes.
///
/// Every subtree walk records the totals of the large folders it passes
/// through (`SizeCache`). Drilling into a folder that's already been measured
/// as part of its parent then costs one directory listing, not another walk
/// of everything beneath it.
public enum DiskScanner {
    /// Cancellation and progress for one scan. Walks check `isCancelled` per
    /// directory, so a scan the user navigated away from stops promptly
    /// instead of running to completion in the background.
    public final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var lastReport = Date.distantPast
        private let onProgress: (@Sendable (String) -> Void)?

        public init(onProgress: (@Sendable (String) -> Void)? = nil) {
            self.onProgress = onProgress
        }

        public func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        public var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        /// Reports the folder being measured, at most five times a second.
        func report(_ path: String) {
            guard let onProgress else { return }
            lock.lock()
            let now = Date()
            let due = now.timeIntervalSince(lastReport) >= 0.2
            if due {
                lastReport = now
            }
            lock.unlock()
            if due {
                onProgress(path)
            }
        }
    }

    /// Totals of large folders seen during walks, keyed by path.
    public final class SizeCache: @unchecked Sendable {
        public static let shared = SizeCache()
        /// Folders smaller than this aren't remembered: re-measuring them is
        /// quick, and remembering every folder on a disk would cost hundreds
        /// of megabytes.
        static let minimumBytes: Int64 = 8_000_000

        private let lock = NSLock()
        private var sizes: [String: Int64] = [:]

        public init() {}

        /// Keys are normalised: the same folder can be spelled with or without
        /// the `/private` prefix depending on which API produced the URL.
        func size(for path: String) -> Int64? {
            let key = PathProtection.normalise(path)
            lock.lock()
            defer { lock.unlock() }
            return sizes[key]
        }

        func record(_ path: String, _ size: Int64) {
            guard size >= Self.minimumBytes else { return }
            let key = PathProtection.normalise(path)
            lock.lock()
            sizes[key] = size
            lock.unlock()
        }

        /// Forgets `path` and everything beneath it (before a rescan, or
        /// after something inside was deleted). Ancestors are forgotten too —
        /// their totals included it.
        public func invalidate(_ path: String) {
            let path = PathProtection.normalise(path)
            lock.lock()
            sizes = sizes.filter { key, _ in
                !(key == path || key.hasPrefix(path + "/") || path.hasPrefix(key + "/"))
            }
            lock.unlock()
        }

        public func removeAll() {
            lock.lock()
            sizes.removeAll()
            lock.unlock()
        }
    }

    private static let walkKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Represents a scanned entry (file or directory) with its allocated disk size.
    public struct Entry: Identifiable, Hashable, Sendable {
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
            id = url.path
            self.url = url
            name = url.lastPathComponent
            self.sizeBytes = sizeBytes
            self.isDirectory = isDirectory
            self.childCount = childCount
            self.isNavigable = isNavigable ?? isDirectory
        }

        /// A non-navigable, computed row (Free space, "macOS System", "Hidden Items").
        init(syntheticName name: String, parent: URL, sizeBytes: Int64, childCount: Int = 0) {
            id = "synthetic://\(name)"
            url = parent.appendingPathComponent(name)
            self.name = name
            self.sizeBytes = sizeBytes
            isDirectory = false
            self.childCount = childCount
            isNavigable = false
        }
    }

    /// Describes the startup volume's capacity for the whole-disk overview.
    public struct VolumeInfo: Hashable, Sendable {
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
    public static func volumeOverview(token: Token? = nil, cache: SizeCache = .shared) -> [Entry] {
        guard let info = startupVolumeInfo() else {
            // No capacity info — degrade to a plain listing of "/".
            return scan(URL(fileURLWithPath: "/"), token: token, cache: cache)
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/")
        let roots = overviewRoots.filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        // Walk the roots concurrently — `/Users` and `/Library` alone are large
        // enough that doing them serially makes the overview feel broken.
        let sizes = concurrentMap(roots) { path in
            measure(URL(fileURLWithPath: path), token: token, cache: cache)
        }
        if token?.isCancelled == true {
            return []
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
    public static func scan(
        _ directory: URL,
        includeHidden: Bool = true,
        token: Token? = nil,
        cache: SizeCache = .shared
    ) -> [Entry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: walkKeys,
            options: []
        ) else {
            return []
        }
        var results: [Entry] = []
        var hiddenTotal: Int64 = 0
        var hiddenCount = 0
        for entry in entries {
            if token?.isCancelled == true {
                return []
            }
            let values = try? entry.resourceValues(forKeys: Set(walkKeys))
            let isDir = values?.isDirectory == true && values?.isSymbolicLink != true
            let size: Int64 = if isDir {
                // Already measured as part of a parent walk? Then this is free.
                cache.size(for: entry.path) ?? measure(entry, token: token, cache: cache)
            } else {
                fileSize(values) ?? allocatedSize(entry)
            }
            if entry.lastPathComponent.hasPrefix(".") && !includeHidden {
                hiddenTotal += size
                hiddenCount += 1
                continue
            }
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
        measure(url, token: nil, cache: nil)
    }

    /// Totals a subtree, recording large folders in `cache` on the way back
    /// up. Never follows a symbolic link, and never descends into another
    /// mounted volume (a network share or disk image under the folder is not
    /// part of *this* disk's usage).
    static func measure(_ url: URL, token: Token?, cache: SizeCache?) -> Int64 {
        if token?.isCancelled == true {
            return 0
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: walkKeys, options: []
        ) else {
            // Not a directory (or unreadable): size of the item itself.
            return allocatedSize(url)
        }
        token?.report(url.path)
        var total: Int64 = 0
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(walkKeys)) else { continue }
            if values.isSymbolicLink == true {
                continue
            }
            if values.isDirectory == true {
                if values.isVolume == true {
                    continue
                }
                total += measure(entry, token: token, cache: cache)
            } else if let size = fileSize(values) {
                total += size
            }
        }
        if token?.isCancelled != true {
            cache?.record(url.path, total)
        }
        return total
    }

    private static func fileSize(_ values: URLResourceValues?) -> Int64? {
        guard let values, values.isRegularFile == true else { return nil }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    /// Best available allocated size for a file URL, falling back to logical size.
    public static func allocatedSize(_ url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey]) {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64
        {
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
        if includeHidden {
            return entries.count
        }
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }.count
    }

    /// Finds the largest files within a directory tree (up to limit).
    /// Includes hidden files — large caches often live under dotfile paths
    /// (e.g. `.cache`, `.npm`) and shouldn't be invisible to this scan.
    public static func largeFiles(in directory: URL, limit: Int = 50, token: Token? = nil) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard limit > 0, let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: []
        ) else { return [] }
        // Keep only the current top `limit`, trimming as we go, so memory
        // stays flat however many files the tree holds.
        var top: [Entry] = []
        var floor: Int64 = 0
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited % 512 == 0, token?.isCancelled == true {
                return []
            }
            guard let size = fileSize(try? fileURL.resourceValues(forKeys: Set(keys))), size > floor else { continue }
            top.append(Entry(url: fileURL, sizeBytes: size, isDirectory: false))
            if top.count >= limit * 2 {
                top.sort { $0.sizeBytes > $1.sizeBytes }
                top.removeLast(top.count - limit)
                floor = top.last?.sizeBytes ?? 0
            }
        }
        return Array(top.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
    }
}
