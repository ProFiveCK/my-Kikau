import Foundation

/// Manages TCC access to `~/Library` subdirectories via security-scoped bookmarks.
/// Mirrors Mole's first-time TCC preflight that prompts for access to
/// `~/Library/{Caches, Logs, Application Support, Containers}`.
public final class Permissions {
    public static let shared = Permissions()

    private let defaults: UserDefaults
    private let bookmarkKey = AppStorageKey.libraryBookmarks

    /// Directories under ~/Library that need user-granted access.
    public static let requiredDirectories: [String] = [
        "Caches",
        "Logs",
        "Application Support",
        "Containers",
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the full URLs for required library subdirectories.
    public func requiredURLs() -> [URL] {
        guard let home = FileManager.default.urls(for: .userDirectory, in: .userDomainMask).first else {
            return []
        }
        return Self.requiredDirectories.map { home.appendingPathComponent($0) }
    }

    /// Checks which required directories are accessible (exist and readable).
    public func checkAccess() -> [URL: Bool] {
        var result: [URL: Bool] = [:]
        for url in requiredURLs() {
            let accessible = FileManager.default.fileExists(atPath: url.path)
                && FileManager.default.isReadableFile(atPath: url.path)
            result[url] = accessible
        }
        return result
    }

    /// Returns true if all required directories are accessible.
    public var hasFullAccess: Bool {
        checkAccess().values.allSatisfy { $0 }
    }

    /// Stores a security-scoped bookmark for a URL.
    public func storeBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = loadBookmarks()
            bookmarks[url.path] = bookmark
            saveBookmarks(bookmarks)
        } catch {
            // Bookmark creation may fail for non-secured locations; ignore.
        }
    }

    /// Resolves and starts accessing a stored bookmark.
    public func resolveBookmark(for path: String) -> Bool {
        let bookmarks = loadBookmarks()
        guard let data = bookmarks[path] else { return false }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                storeBookmark(for: url)
            }
            return url.startAccessingSecurityScopedResource()
        } catch {
            return false
        }
    }

    private func loadBookmarks() -> [String: Data] {
        if let data = defaults.data(forKey: bookmarkKey),
           let dict = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            return dict
        }
        return [:]
    }

    private func saveBookmarks(_ bookmarks: [String: Data]) {
        if let data = try? PropertyListEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarkKey)
        }
    }
}