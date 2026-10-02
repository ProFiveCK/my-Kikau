import CryptoKit
import Foundation
import Core

/// Finds duplicate files (by content, not just name) and separately surfaces
/// large files, across the user's own content folders.
///
/// Deliberately scoped to Downloads/Documents/Desktop/Pictures/Movies (plus
/// any folders the user adds in Settings), not `~/Library` or anywhere
/// app-owned — Clean and Purge already own app/dev data. This is the "My
/// Clutter" equivalent: things the user put there themselves that may be
/// worth reviewing.
public enum DuplicateFinder {
    /// A single scanned file.
    public struct FileEntry: Identifiable, Hashable, Sendable {
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

    /// A set of files with identical content. `files.first` is the keeper
    /// (most recently modified unless the user picks another); the rest are
    /// the reclaimable copies.
    public struct DuplicateGroup: Identifiable, Sendable {
        public let id: String  // content hash
        public let files: [FileEntry]
        public let sizeBytes: Int64  // size of a single copy

        public init(id: String, files: [FileEntry], sizeBytes: Int64) {
            self.id = id
            self.files = files
            self.sizeBytes = sizeBytes
        }

        public var keeper: FileEntry? { files.first }
        public var reclaimableBytes: Int64 { sizeBytes * Int64(max(0, files.count - 1)) }

        /// The same group with a different file chosen as the one to keep.
        public func keeping(_ fileID: String) -> DuplicateGroup {
            guard let index = files.firstIndex(where: { $0.id == fileID }), index != 0 else { return self }
            var reordered = files
            reordered.insert(reordered.remove(at: index), at: 0)
            return DuplicateGroup(id: id, files: reordered, sizeBytes: sizeBytes)
        }

        /// The group without the given files (after they've been removed).
        /// `nil` once fewer than two copies remain.
        public func removing(_ fileIDs: Set<String>) -> DuplicateGroup? {
            let remaining = files.filter { !fileIDs.contains($0.id) }
            return remaining.count > 1 ? DuplicateGroup(id: id, files: remaining, sizeBytes: sizeBytes) : nil
        }
    }

    /// What a walk skipped, so the UI can say why a count looks low.
    public struct WalkReport: Sendable {
        public var files: [FileEntry] = []
        /// Files stored in iCloud and not downloaded. Reading them to hash
        /// would download them, so they're left out.
        public var skippedCloudOnly = 0
    }

    /// Directories scanned by default, relative to the home directory.
    public static let defaultScanPaths: [String] = [
        "Downloads", "Documents", "Desktop", "Pictures", "Movies",
    ]

    /// Files smaller than this are never hashed — not worth the dedup UI
    /// attention, and skipping them keeps large home folders fast to scan.
    private static let minDuplicateSize: Int64 = 1_000_000  // 1 MB

    public static let defaultLargeFileThresholdMB = 100

    /// Threshold for the separate "large files" list (Settings → Files).
    public static var largeFileThreshold: Int64 {
        let stored = UserDefaults.standard.integer(forKey: AppStorageKey.largeFileThresholdMB)
        return Int64(stored > 0 ? stored : defaultLargeFileThresholdMB) * 1_000_000
    }

    /// Bytes read from each end of a file for the cheap first-pass hash.
    private static let partialHashBytes = 64 * 1024

    public static func scanPaths(home: URL? = nil) -> [URL] {
        let resolvedHome = home ?? FileManager.default.homeDirectoryForCurrentUser
        var paths = defaultScanPaths.map { resolvedHome.appendingPathComponent($0) }
        // Extra folders only apply to the real home — tests inject their own.
        if home == nil {
            let extra = UserDefaults.standard.stringArray(forKey: AppStorageKey.fileScanFolders) ?? []
            for path in extra where !paths.contains(where: { $0.path == path }) {
                paths.append(URL(fileURLWithPath: path))
            }
        }
        return paths
    }

    /// Walks every scan path once and returns each regular file found.
    /// Shared by both `findDuplicates` and `findLargeFiles` so a caller doing
    /// both only walks the filesystem once (pass the result to `allFiles:`).
    public static func walk(home: URL? = nil) -> [FileEntry] {
        walkReport(home: home).files
    }

    /// `walk`, plus counts of what was skipped. Stops early if the
    /// surrounding task is cancelled.
    ///
    /// - A file with several hard links is returned once: its "copies" share
    ///   the same storage, so removing one frees nothing.
    /// - Files that live in iCloud and aren't downloaded are skipped.
    public static func walkReport(home: URL? = nil, onProgress: ((Int) -> Void)? = nil) -> WalkReport {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .fileSizeKey, .isRegularFileKey, .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        var report = WalkReport()
        var seenIdentifiers = Set<AnyHashable>()
        var visited = 0
        for root in scanPaths(home: home) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                visited += 1
                if visited % 256 == 0 {
                    if Task.isCancelled { return report }
                    onProgress?(visited)
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, let size = values.fileSize, size > 0 else { continue }
                if isCloudOnly(values, path: url.path, size: Int64(size)) {
                    report.skippedCloudOnly += 1
                    continue
                }
                if let identifier = values.fileResourceIdentifier as? NSObject,
                   !seenIdentifiers.insert(AnyHashable(identifier)).inserted {
                    continue
                }
                report.files.append(FileEntry(url: url, sizeBytes: Int64(size), modified: values.contentModificationDate))
            }
        }
        return report
    }

    private static func isCloudOnly(_ values: URLResourceValues, path: String, size: Int64) -> Bool {
        if values.isUbiquitousItem == true,
           let status = values.ubiquitousItemDownloadingStatus, status != .current {
            return true
        }
        // File Provider placeholders (iCloud Drive, OneDrive, Dropbox…) carry
        // the SF_DATALESS flag: full logical size, no content on disk. Only
        // worth the extra stat for files big enough to be listed or hashed.
        guard size >= minDuplicateSize else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & 0x4000_0000 != 0
    }

    /// True duplicates, found in three passes so little is ever read:
    /// 1. bucket by exact size (free);
    /// 2. within a size bucket, bucket by a hash of the first and last 64 KB;
    /// 3. only files that still collide get a full streamed SHA-256.
    ///
    /// A file that can't be read completely is dropped rather than matched on
    /// a partial hash. Stops early if the surrounding task is cancelled.
    public static func findDuplicates(
        home: URL? = nil,
        allFiles: [FileEntry]? = nil,
        onProgress: ((_ hashed: Int, _ total: Int) -> Void)? = nil
    ) -> [DuplicateGroup] {
        let files = allFiles ?? walk(home: home)
        let candidates = files.filter { $0.sizeBytes >= minDuplicateSize }

        var bySize: [Int64: [FileEntry]] = [:]
        for f in candidates { bySize[f.sizeBytes, default: []].append(f) }
        let sizeBuckets = bySize.filter { $0.value.count > 1 }
        let total = sizeBuckets.values.reduce(0) { $0 + $1.count }
        var hashed = 0

        var groups: [DuplicateGroup] = []
        for (size, sameSize) in sizeBuckets {
            var byPartial: [String: [FileEntry]] = [:]
            for f in sameSize {
                if Task.isCancelled { return [] }
                hashed += 1
                onProgress?(hashed, total)
                guard let partial = partialHash(f.url, size: size) else { continue }
                byPartial[partial, default: []].append(f)
            }
            for (_, samePartial) in byPartial where samePartial.count > 1 {
                var byHash: [String: [FileEntry]] = [:]
                // A file no bigger than the two sampled ends has already been
                // hashed in full by the partial pass.
                let fullyCovered = size <= Int64(partialHashBytes * 2)
                for f in samePartial {
                    if Task.isCancelled { return [] }
                    guard let hash = fullyCovered ? partialHash(f.url, size: size) : contentHash(f.url) else { continue }
                    byHash[hash, default: []].append(f)
                }
                for (hash, matched) in byHash where matched.count > 1 {
                    let sorted = matched.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                    groups.append(DuplicateGroup(id: hash, files: sorted, sizeBytes: size))
                }
            }
        }
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Files at or above the large-file threshold, largest first. Simple
    /// size-sort mode — no hashing, so it's effectively free after `walk`.
    public static func findLargeFiles(
        home: URL? = nil,
        allFiles: [FileEntry]? = nil,
        threshold: Int64? = nil
    ) -> [FileEntry] {
        let files = allFiles ?? walk(home: home)
        let minimum = threshold ?? largeFileThreshold
        return files.filter { $0.sizeBytes >= minimum }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Deletion plan for every file in `groups` except each group's keeper
    /// (`files.first`).
    ///
    /// Scan results can be hours old, so each group is checked again first
    /// (`stillValid`): a group whose keeper has gone or changed is left out
    /// entirely — its "copies" may now be the only copies.
    public static func duplicatePlan(for groups: [DuplicateGroup], deleter: SafeFileDeleter = .shared) -> SafeFileDeleter.Plan {
        let urls = groups.compactMap(stillValid).flatMap { $0.files.dropFirst().map(\.url) }
        return deleter.preview(urls, category: .duplicate)
    }

    /// The group as it stands on disk now: the keeper must still exist
    /// unchanged, and only copies that are unchanged since the scan remain.
    /// `nil` if the keeper changed or no unchanged copy is left.
    public static func stillValid(_ group: DuplicateGroup) -> DuplicateGroup? {
        guard let keeper = group.keeper, isUnchanged(keeper) else { return nil }
        let copies = group.files.dropFirst().filter(isUnchanged)
        guard !copies.isEmpty else { return nil }
        return DuplicateGroup(id: group.id, files: [keeper] + copies, sizeBytes: group.sizeBytes)
    }

    /// Same size and modification time as when it was scanned.
    private static func isUnchanged(_ file: FileEntry) -> Bool {
        // A fresh URL: the scanned one may still carry cached resource values.
        let url = URL(fileURLWithPath: file.url.path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize, Int64(size) == file.sizeBytes else { return false }
        return values.contentModificationDate == file.modified
    }

    /// Deletion plan for a selected set of large files.
    public static func largeFilePlan(for files: [FileEntry], deleter: SafeFileDeleter = .shared) -> SafeFileDeleter.Plan {
        deleter.preview(files.map(\.url), category: .largeFile)
    }

    /// SHA-256 of the first and last `partialHashBytes` of the file. `nil` if
    /// either read fails.
    static func partialHash(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: partialHashBytes), !head.isEmpty else { return nil }
        hasher.update(data: head)
        if size > Int64(partialHashBytes) {
            let tailStart = UInt64(max(Int64(partialHashBytes), size - Int64(partialHashBytes)))
            guard (try? handle.seek(toOffset: tailStart)) != nil,
                  let tail = try? handle.read(upToCount: partialHashBytes) else { return nil }
            hasher.update(data: tail)
        }
        return hex(hasher.finalize())
    }

    /// Streamed SHA-256 so multi-GB files (movies, disk images) don't have to
    /// be loaded into memory whole to be hashed. Returns `nil` if any read
    /// fails — a hash of part of a file must never stand in for the whole.
    static func contentHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var count = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1_048_576)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            count += 1
            if count % 64 == 0, Task.isCancelled { return nil }
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
