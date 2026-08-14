import CryptoKit
import Foundation
import Core

/// Finds duplicate files (by content, not just name) and separately surfaces
/// large files, across the user's own content folders.
///
/// Deliberately scoped to Downloads/Documents/Desktop/Pictures/Movies, not
/// `~/Library` or anywhere app-owned — Clean and Purge already own app/dev
/// data. This is the "My Clutter" equivalent: things the user put there
/// themselves that may be worth reviewing.
public enum DuplicateFinder {
    /// A single scanned file.
    public struct FileEntry: Identifiable, Hashable {
        public let id: String
        public let url: URL
        public let sizeBytes: Int64
        public let modified: Date?

        public init(url: URL, sizeBytes: Int64, modified: Date?) {
            self.id = url.path
            self.url = url
            self.sizeBytes = sizeBytes
            self.modified = modified
        }
    }

    /// A set of files with identical content. `files.first` is the suggested
    /// keeper (most recently modified); the rest are the reclaimable copies.
    public struct DuplicateGroup: Identifiable {
        public let id: String  // content hash
        public let files: [FileEntry]
        public let sizeBytes: Int64  // size of a single copy

        public var reclaimableBytes: Int64 { sizeBytes * Int64(files.count - 1) }
    }

    /// Directories scanned by default, relative to the home directory.
    public static let defaultScanPaths: [String] = [
        "Downloads", "Documents", "Desktop", "Pictures", "Movies",
    ]

    /// Files smaller than this are never hashed — not worth the dedup UI
    /// attention, and skipping them keeps large home folders fast to scan.
    private static let minDuplicateSize: Int64 = 1_000_000  // 1 MB

    /// Threshold for the separate "large files" list.
    private static let largeFileThreshold: Int64 = 100_000_000  // 100 MB

    public static func scanPaths(home: URL? = nil) -> [URL] {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        return defaultScanPaths.map { home.appendingPathComponent($0) }
    }

    /// Walks every scan path once and returns each regular file found.
    /// Shared by both `findDuplicates` and `findLargeFiles` so a caller doing
    /// both only walks the filesystem once (pass the result to `allFiles:`).
    public static func walk(home: URL? = nil) -> [FileEntry] {
        let fm = FileManager.default
        var entries: [FileEntry] = []
        for root in scanPaths(home: home) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
                ), values.isRegularFile == true, let size = values.fileSize, size > 0 else { continue }
                entries.append(FileEntry(url: url, sizeBytes: Int64(size), modified: values.contentModificationDate))
            }
        }
        return entries
    }

    /// True duplicates: bucketed by exact file size first (cheap), then
    /// confirmed by a streamed SHA-256 content hash within each size bucket
    /// — files are only ever hashed if something else already shares their
    /// exact size, which keeps this fast even on large home folders.
    public static func findDuplicates(home: URL? = nil, allFiles: [FileEntry]? = nil) -> [DuplicateGroup] {
        let files = allFiles ?? walk(home: home)
        let candidates = files.filter { $0.sizeBytes >= minDuplicateSize }

        var bySize: [Int64: [FileEntry]] = [:]
        for f in candidates { bySize[f.sizeBytes, default: []].append(f) }

        var groups: [DuplicateGroup] = []
        for (size, sameSize) in bySize where sameSize.count > 1 {
            var byHash: [String: [FileEntry]] = [:]
            for f in sameSize {
                guard let hash = contentHash(f.url) else { continue }
                byHash[hash, default: []].append(f)
            }
            for (hash, matched) in byHash where matched.count > 1 {
                let sorted = matched.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                groups.append(DuplicateGroup(id: hash, files: sorted, sizeBytes: size))
            }
        }
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Files at or above the large-file threshold, largest first. Simple
    /// size-sort mode — no hashing, so it's effectively free after `walk`.
    public static func findLargeFiles(home: URL? = nil, allFiles: [FileEntry]? = nil) -> [FileEntry] {
        let files = allFiles ?? walk(home: home)
        return files.filter { $0.sizeBytes >= largeFileThreshold }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Deletion plan for every file in `groups` except each group's suggested
    /// keeper (`files.first`).
    public static func duplicatePlan(for groups: [DuplicateGroup], deleter: SafeFileDeleter = .shared) -> SafeFileDeleter.Plan {
        let urls = groups.flatMap { $0.files.dropFirst().map(\.url) }
        return deleter.preview(urls, category: .duplicate)
    }

    /// Deletion plan for a selected set of large files.
    public static func largeFilePlan(for files: [FileEntry], deleter: SafeFileDeleter = .shared) -> SafeFileDeleter.Plan {
        deleter.preview(files.map(\.url), category: .largeFile)
    }

    /// Streamed SHA-256 so multi-GB files (movies, disk images) don't have to
    /// be loaded into memory whole to be hashed.
    private static func contentHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1_048_576)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().description
    }
}
