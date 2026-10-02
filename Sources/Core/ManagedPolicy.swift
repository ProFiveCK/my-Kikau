import Foundation

/// The preference domain every myKikau process reads settings and policy
/// from. The app uses its own (`.standard`); the command-line tool points this
/// at the app's domain at startup so both honour the same policy and exclusions.
public enum AppDefaults {
    public static let appDomain = "com.profiveck.myKikau"
    nonisolated(unsafe) public static var store: UserDefaults = .standard
}

/// Administrator policy, delivered by an MDM configuration profile for the
/// app's preference domain (`com.profiveck.myKikau`). See
/// `docs/ENTERPRISE_DEPLOYMENT.md` for the key reference and a sample profile.
///
/// A key counts as policy only when it is *forced* (`objectIsForced(forKey:)`)
/// — a value a user wrote with `defaults write` is ignored, so policy can't be
/// spoofed or loosened locally. Every accessor falls back to "no restriction".
public struct ManagedPolicy {
    public enum Key {
        public static let disabledFeatures = "DisabledFeatures"
        public static let protectedPaths = "ProtectedPaths"
        public static let protectedBundlePrefixes = "ProtectedBundlePrefixes"
        public static let forceOperationLog = "ForceOperationLog"
        public static let disableAutomaticUpdates = "DisableAutomaticUpdates"
        public static let disablePrivilegedTools = "DisablePrivilegedTools"
        public static let scheduledScanIntervalHours = "ScheduledScanIntervalHours"
    }

    private let defaults: UserDefaults
    /// Tests inject plain (unforced) values through a throwaway suite.
    private let requireForced: Bool

    public static var shared: ManagedPolicy { ManagedPolicy(defaults: AppDefaults.store) }

    public init(defaults: UserDefaults = AppDefaults.store, requireForced: Bool = true) {
        self.defaults = defaults
        self.requireForced = requireForced
    }

    private func managed(_ key: String) -> Any? {
        if requireForced, !defaults.objectIsForced(forKey: key) { return nil }
        return defaults.object(forKey: key)
    }

    /// True when at least one policy key is being enforced on this Mac.
    public var isManaged: Bool {
        [Key.disabledFeatures, Key.protectedPaths, Key.protectedBundlePrefixes, Key.forceOperationLog,
         Key.disableAutomaticUpdates, Key.disablePrivilegedTools, Key.scheduledScanIntervalHours]
            .contains { managed($0) != nil }
    }

    /// Sidebar identifiers (`clean`, `uninstall`, `analyze`, `duplicates`,
    /// `network`, `optimize`, `purge`) hidden by policy.
    public var disabledFeatures: Set<String> {
        Set((managed(Key.disabledFeatures) as? [String] ?? []).map { $0.lowercased() })
    }

    public func isFeatureDisabled(_ id: String) -> Bool {
        disabledFeatures.contains(id.lowercased())
    }

    /// Extra paths (subtrees) that must never be deleted.
    public var protectedPaths: [String] {
        managed(Key.protectedPaths) as? [String] ?? []
    }

    /// Extra bundle-ID prefixes treated like endpoint-security agents.
    public var protectedBundlePrefixes: [String] {
        managed(Key.protectedBundlePrefixes) as? [String] ?? []
    }

    /// The operation log can't be switched off.
    public var forceOperationLog: Bool {
        managed(Key.forceOperationLog) as? Bool ?? false
    }

    public var disableAutomaticUpdates: Bool {
        managed(Key.disableAutomaticUpdates) as? Bool ?? false
    }

    /// Hides actions that ask for an administrator password.
    public var disablePrivilegedTools: Bool {
        managed(Key.disablePrivilegedTools) as? Bool ?? false
    }

    /// Hours between background scans, when an administrator sets one.
    public var scheduledScanIntervalHours: Int? {
        guard let hours = managed(Key.scheduledScanIntervalHours) as? Int, hours > 0 else { return nil }
        return hours
    }
}
