import Foundation

/// The one way myKikau measures how much disk an item takes.
///
/// Uses allocated size where available, rather than logical file length.
/// This is an estimate: shared APFS blocks and snapshots can change actual
/// free-space gains. Hidden files are
/// included; symbolic links are not followed; other mounted volumes under
/// the folder are not entered.
public enum FileSizing {
    public static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Bytes a single regular file occupies, from pre-fetched resource
    /// values; `nil` for anything that isn't a regular file.
    public static func fileSize(_ values: URLResourceValues?) -> Int64? {
        guard let values, values.isRegularFile == true else { return nil }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    /// Total allocated bytes of a file or folder tree.
    /// - Parameter shouldContinue: polled every few hundred entries; return
    ///   `false` to stop early (the partial total is returned).
    public static func allocatedSize(
        of url: URL,
        fileManager: FileManager = .default,
        coverage: ScanCoverageRecorder? = nil,
        shouldContinue: () -> Bool = { !Task.isCancelled }
    ) -> Int64 {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: keys) }
        catch { coverage?.failed(url, error: error); return 0 }
        if values.isSymbolicLink == true {
            return 0
        }
        if values.isDirectory != true {
            return fileSize(values) ?? 0
        }

        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { path, error in coverage?.failed(path, error: error); return true }
        ) else {
            coverage?.record(url, kind: .unavailable, detail: "The folder could not be enumerated.")
            return 0
        }
        var total: Int64 = 0
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited % 512 == 0, !shouldContinue() {
                break
            }
            let childValues: URLResourceValues
            do { childValues = try child.resourceValues(forKeys: keys) }
            catch { coverage?.failed(child, error: error); continue }
            if childValues.isSymbolicLink == true {
                continue
            }
            if childValues.isDirectory == true {
                // Another volume mounted inside this folder isn't this folder's usage.
                if childValues.isVolume == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            total += fileSize(childValues) ?? 0
        }
        return total
    }
}
