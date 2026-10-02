import Foundation

/// Paths the user (Settings → Exclusions) or an administrator (managed
/// preference `ProtectedPaths`) has said myKikau must never delete.
/// `PathProtection` consults this on every check, so an exclusion applies to
/// every feature that deletes through `SafeFileDeleter`.
public final class ExclusionStore: @unchecked Sendable {
    public static let shared = ExclusionStore()

    private let injectedDefaults: UserDefaults?
    private var defaults: UserDefaults {
        injectedDefaults ?? AppDefaults.store
    }

    private let lock = NSLock()
    private var cached: [String]?
    private var cachedAt = Date.distantPast
    /// A profile can add or remove managed paths while the app is running.
    private static let cacheLifetime: TimeInterval = 30

    public init(defaults: UserDefaults? = nil) {
        injectedDefaults = defaults
    }

    /// Exclusions the user added. Editable.
    public var userPaths: [String] {
        defaults.stringArray(forKey: AppStorageKey.userExclusions) ?? []
    }

    /// Exclusions forced by a configuration profile. Read-only in the UI.
    public var managedPaths: [String] {
        ManagedPolicy(defaults: defaults).protectedPaths
    }

    public func setUserPaths(_ paths: [String]) {
        var seen = Set<String>()
        let unique = paths.filter { !$0.isEmpty && seen.insert($0).inserted }
        defaults.set(unique, forKey: AppStorageKey.userExclusions)
        invalidate()
    }

    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// User and managed exclusions, normalised for prefix comparison.
    public var normalisedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cachedAt) < Self.cacheLifetime {
            return cached
        }
        let all = (userPaths + managedPaths).map {
            PathProtection.normalise(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path)
        }
        cached = all
        cachedAt = Date()
        return all
    }
}
