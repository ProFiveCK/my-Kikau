import Foundation

/// Best-effort check for whether the app currently holds Full Disk Access.
///
/// myKikau ships unsandboxed (direct distribution, not the Mac App Store — see
/// docs/MODERNIZATION_REVIEW.md §5), so Full Disk Access — not App Sandbox
/// entitlements or security-scoped bookmarks — is what unlocks reading other
/// apps' `~/Library` data, Mail, Time Machine paths, etc.
///
/// There is no public API to ask "do I have FDA," so — like most FDA-gated
/// utilities — this probes a couple of paths that are only readable *with*
/// FDA granted, and unreadable (not merely absent) without it. It's a
/// heuristic, not a guarantee; treat a `false` result as "probably not
/// granted," not as authoritative.
public enum FullDiskAccessCheck {
    private static let probePaths: [String] = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/CloudTabs.db",
    ]

    /// Returns true if any known FDA-gated path can actually be opened for reading.
    ///
    /// Deliberately does NOT use `FileManager.isReadableFile(atPath:)` — that wraps
    /// the POSIX `access()` syscall, which only checks ordinary Unix permission bits
    /// and is not reliably gated by TCC/Full Disk Access. `open()` (via `FileHandle`)
    /// is what TCC actually intercepts for protected paths, so that's what has to be
    /// attempted for this probe to mean anything.
    public static func probe() -> Bool {
        probePaths.contains { canActuallyOpen($0) }
    }

    private static func canActuallyOpen(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return true
    }
}
