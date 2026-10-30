import Foundation

/// The preference domain every myKikau process reads settings and policy
/// from. The app uses its own (`.standard`); the command-line tool points this
/// at the app's domain at startup so both honour the same policy and exclusions.
public enum AppDefaults {
    public static let appDomain = "com.profiveck.myKikau"
    public nonisolated(unsafe) static var store: UserDefaults = .standard
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
        public static let organisationName = "OrganisationName"
        public static let supportContact = "SupportContact"
        public static let launchAtLogin = "LaunchAtLogin"
        public static let disableNetworkLookups = "DisableNetworkLookups"
    }

    /// Every key, in the order the docs list them.
    public static let allKeys: [String] = [
        Key.disabledFeatures, Key.protectedPaths, Key.protectedBundlePrefixes, Key.forceOperationLog,
        Key.disableAutomaticUpdates, Key.disablePrivilegedTools, Key.scheduledScanIntervalHours,
        Key.organisationName, Key.supportContact, Key.launchAtLogin, Key.disableNetworkLookups,
    ]

    private let defaults: UserDefaults
    /// Tests inject plain (unforced) values through a throwaway suite.
    private let requireForced: Bool

    public static var shared: ManagedPolicy {
        ManagedPolicy(defaults: AppDefaults.store)
    }

    public init(defaults: UserDefaults = AppDefaults.store, requireForced: Bool = true) {
        self.defaults = defaults
        self.requireForced = requireForced
    }

    private func managed(_ key: String) -> Any? {
        if requireForced, !defaults.objectIsForced(forKey: key) {
            return nil
        }
        return defaults.object(forKey: key)
    }

    /// True when at least one policy key is being enforced on this Mac.
    public var isManaged: Bool {
        Self.allKeys.contains { managed($0) != nil }
    }

    /// Sidebar identifiers (`clean`, `uninstall`, `analyze`, `duplicates`,
    /// `network`, `optimize`, `startup`, `purge`) hidden by policy.
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

    /// The updater is switched off entirely: no background checks, and no
    /// "Check for Updates…" controls. The organisation deploys updates itself.
    public var disableAutomaticUpdates: Bool {
        managed(Key.disableAutomaticUpdates) as? Bool ?? false
    }

    /// Shown in About and Settings so people know who manages the app.
    public var organisationName: String? {
        nonEmpty(managed(Key.organisationName) as? String)
    }

    /// Where to go for help: an https URL, a mailto: address, or plain text.
    public var supportContact: String? {
        nonEmpty(managed(Key.supportContact) as? String)
    }

    /// Registers (true) or unregisters (false) the app as a login item at
    /// every launch, and locks the toggle in Settings.
    public var launchAtLogin: Bool? {
        managed(Key.launchAtLogin) as? Bool
    }

    /// Hides the two on-request lookups that contact third parties: the app
    /// update check (Apple and each app's own feed) and the public IP lookup.
    public var disableNetworkLookups: Bool {
        managed(Key.disableNetworkLookups) as? Bool ?? false
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
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

/// The subset of policy a root process (the privileged helper) can read
/// without a user's preference domain: the profile plists macOS writes under
/// `/Library/Managed Preferences`. Device-scope profiles land in the top
/// folder, user-scope ones in a folder named after the account.
public struct ManagedProtectionPolicy: Equatable, Sendable {
    public var protectedPaths: [String]
    public var protectedBundlePrefixes: [String]

    public init(protectedPaths: [String] = [], protectedBundlePrefixes: [String] = []) {
        self.protectedPaths = protectedPaths
        self.protectedBundlePrefixes = protectedBundlePrefixes
    }

    public static let managedPreferencesRoot = "/Library/Managed Preferences"

    /// Reads the device profile and, when `userName` is given, that user's
    /// profile; both apply. A missing or unreadable plist contributes nothing.
    public static func load(
        userName: String?,
        root: String = managedPreferencesRoot,
        domain: String = AppDefaults.appDomain
    ) -> ManagedProtectionPolicy {
        var files = [root + "/" + domain + ".plist"]
        if let userName, !userName.isEmpty, !userName.contains("/") {
            files.append(root + "/" + userName + "/" + domain + ".plist")
        }
        var policy = ManagedProtectionPolicy()
        for file in files {
            guard let dictionary = NSDictionary(contentsOfFile: file) else { continue }
            policy.protectedPaths += dictionary[ManagedPolicy.Key.protectedPaths] as? [String] ?? []
            policy.protectedBundlePrefixes += dictionary[ManagedPolicy.Key.protectedBundlePrefixes] as? [String] ?? []
        }
        return policy
    }

    /// Paths normalised the way `PathProtection` compares them.
    public var normalisedPaths: [String] {
        protectedPaths.map { PathProtection.normalise(URL(fileURLWithPath: $0).standardizedFileURL.path) }
    }
}
