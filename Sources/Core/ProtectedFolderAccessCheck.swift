import Foundation

/// Best-effort check for whether the app can actually read the "personal
/// folders" macOS gates independently of Full Disk Access: Desktop,
/// Documents, and Downloads. This is exactly what `DuplicateFinder` and
/// `DiskScanner` walk — if TCC hasn't granted this (a separate toggle under
/// System Settings → Privacy & Security → Files and Folders, distinct from
/// the "Full Disk Access" list `FullDiskAccessCheck` probes), those scans
/// don't throw or fail visibly: `FileManager.enumerator(at:)` is created with
/// no `errorHandler`, so per Apple's documented default it just silently
/// stops enumerating rather than surfacing an error, and the caller sees an
/// empty result indistinguishable from "genuinely nothing there." That's the
/// most likely explanation for Duplicates/Large Files reporting nothing scan
/// after scan even on a Mac that obviously has files in Downloads.
public enum ProtectedFolderAccessCheck {
    private static let probeFolders = ["Desktop", "Documents", "Downloads"]

    /// Names of protected folders that exist but can't currently be listed.
    /// Empty means every folder that exists is readable (a folder that
    /// doesn't exist at all is not reported — nothing to scan there either way).
    public static func deniedFolders() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return probeFolders.filter { name in
            let path = home.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { return false }
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) == nil
        }
    }

    /// True if none of the probed folders are denied.
    public static func probe() -> Bool {
        deniedFolders().isEmpty
    }
}
