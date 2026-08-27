import Foundation

/// Audits macOS Local Network privacy rules without modifying Apple's
/// Network Extension preference store.
public enum NetworkPrivacyAuditor {
    public static let systemArchiveURL = URL(
        fileURLWithPath: "/Library/Preferences/com.apple.networkextension.plist"
    )

    public enum ArchiveError: LocalizedError {
        case invalidKeyedArchive

        public var errorDescription: String? {
            switch self {
            case .invalidKeyedArchive: "The Network Extension preference file is not a valid keyed archive."
            }
        }
    }

    public struct Rule: Hashable, Sendable {
        public let signingIdentifier: String
        public let executablePath: String?
        public let isDenied: Bool
        public let preferenceWasSet: Bool

        public init(
            signingIdentifier: String,
            executablePath: String?,
            isDenied: Bool,
            preferenceWasSet: Bool
        ) {
            self.signingIdentifier = signingIdentifier
            self.executablePath = executablePath
            self.isDenied = isDenied
            self.preferenceWasSet = preferenceWasSet
        }
    }

    public struct InstalledApplication: Hashable, Sendable {
        public let bundleIdentifier: String
        public let executablePath: String

        public init(bundleIdentifier: String, executablePath: String) {
            self.bundleIdentifier = bundleIdentifier
            self.executablePath = executablePath
        }
    }

    public enum FindingKind: String, Hashable, Sendable {
        case excessivePrivacyRecords
        case installedApplicationDenied
        case conflictingPrivacyDecisions
        case stalePrivacyRecords
    }

    public enum Severity: Int, Hashable, Sendable, Comparable {
        case information
        case warning
        case critical

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public enum Remediation: String, Hashable, Sendable {
        case automatic
        case guidedRecovery
        case manual
    }

    public struct Finding: Identifiable, Hashable, Sendable {
        public let kind: FindingKind
        public let severity: Severity
        public let signingIdentifier: String
        public let affectedRecordCount: Int
        public let remediation: Remediation
        public let detail: String

        public var id: String { "\(kind.rawValue):\(signingIdentifier)" }
    }

    public struct Report: Hashable, Sendable {
        public let findings: [Finding]
        public let inspectedRuleCount: Int

        public var autoFixableCount: Int {
            findings.count { $0.remediation == .automatic }
        }

        public var issueCount: Int { findings.count }
        public var isHealthy: Bool { findings.isEmpty }
    }

    /// Decodes only the path-controller fields needed for the audit. The file
    /// is an `NSKeyedArchiver` containing private NetworkExtension classes, so
    /// using `NSKeyedUnarchiver` would try to instantiate unavailable private
    /// types. Property-list decoding keeps it as inert dictionaries and UIDs.
    public static func loadRules(from archiveURL: URL) throws -> [Rule] {
        let data = try Data(contentsOf: archiveURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let archive = plist as? [String: Any],
              archive["$archiver"] as? String == "NSKeyedArchiver",
              let objects = archive["$objects"] as? [Any]
        else {
            throw ArchiveError.invalidKeyedArchive
        }

        var rules: [Rule] = []
        for case let object as [String: Any] in objects {
            guard let signingIdentifier = resolveString(object["SigningIdentifier"], objects: objects),
                  let isDenied = object["DenyMulticast"] as? Bool,
                  let preferenceWasSet = object["MulticastPreferenceSet"] as? Bool
            else {
                continue
            }
            let rawPath = resolveString(object["Path"], objects: objects)
            rules.append(Rule(
                signingIdentifier: signingIdentifier,
                executablePath: rawPath == "$null" ? nil : rawPath,
                isDenied: isDenied,
                preferenceWasSet: preferenceWasSet
            ))
        }
        return rules
    }

    public static func inspect(
        archiveURL: URL = systemArchiveURL,
        installedApplications: [InstalledApplication],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> Report {
        audit(
            rules: try loadRules(from: archiveURL),
            installedApplications: installedApplications,
            fileExists: fileExists
        )
    }

    /// Lightweight app identity inventory for privacy-rule correlation. This
    /// deliberately avoids `AppInventory.scan()`, which calculates every app's
    /// directory size and would make a settings-health scan unnecessarily slow.
    public static func discoverInstalledApplications(
        in applicationDirectories: [URL]? = nil
    ) -> [InstalledApplication] {
        let directories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var applications: Set<InstalledApplication> = []
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for appURL in entries where appURL.pathExtension == "app" {
                guard let bundle = Bundle(path: appURL.path),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      let executablePath = bundle.executableURL?.path
                else {
                    continue
                }
                applications.insert(.init(
                    bundleIdentifier: bundleIdentifier,
                    executablePath: executablePath
                ))
            }
        }
        return applications.sorted {
            if $0.bundleIdentifier != $1.bundleIdentifier {
                return $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending
            }
            return $0.executablePath.localizedCaseInsensitiveCompare($1.executablePath) == .orderedAscending
        }
    }

    /// More than ten explicit records for one signing identifier is never a
    /// normal steady state. Chrome's updater can leave `code_sign_clone` paths
    /// behind, producing many conflicting entries in System Settings.
    public static func audit(
        rules: [Rule],
        installedApplications: [InstalledApplication],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Report {
        let explicitRules = rules.filter(\.preferenceWasSet)
        let groups = Dictionary(grouping: explicitRules, by: \.signingIdentifier)
        let installedByBundleID = Dictionary(grouping: installedApplications, by: \.bundleIdentifier)
        var findings: [Finding] = []

        for (signingIdentifier, appRules) in groups {
            if appRules.count > 10 {
                findings.append(Finding(
                    kind: .excessivePrivacyRecords,
                    severity: .critical,
                    signingIdentifier: signingIdentifier,
                    affectedRecordCount: appRules.count,
                    remediation: .guidedRecovery,
                    detail: "\(appRules.count) Local Network privacy records found; macOS has no supported per-app reset."
                ))
            }

            let stale = appRules.filter { rule in
                guard let path = rule.executablePath, path != "$null" else { return false }
                return !fileExists(path)
            }
            if !stale.isEmpty {
                findings.append(Finding(
                    kind: .stalePrivacyRecords,
                    severity: .warning,
                    signingIdentifier: signingIdentifier,
                    affectedRecordCount: stale.count,
                    remediation: .guidedRecovery,
                    detail: "\(stale.count) record(s) point to executable paths that no longer exist."
                ))
            }

            if Set(appRules.map(\.isDenied)).count > 1 {
                findings.append(Finding(
                    kind: .conflictingPrivacyDecisions,
                    severity: .critical,
                    signingIdentifier: signingIdentifier,
                    affectedRecordCount: appRules.count,
                    remediation: .guidedRecovery,
                    detail: "Local Network records disagree about whether this app is allowed."
                ))
            }

            let installed = installedByBundleID[signingIdentifier] ?? []
            let installedDenied = appRules.contains { rule in
                guard rule.isDenied else { return false }
                guard let path = rule.executablePath, path != "$null" else {
                    return !installed.isEmpty
                }
                return installed.contains { $0.executablePath == path }
            }
            if installedDenied {
                findings.append(Finding(
                    kind: .installedApplicationDenied,
                    severity: .critical,
                    signingIdentifier: signingIdentifier,
                    affectedRecordCount: appRules.filter(\.isDenied).count,
                    remediation: .guidedRecovery,
                    detail: "The installed application is explicitly denied Local Network access."
                ))
            }
        }

        findings.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if findingPriority($0.kind) != findingPriority($1.kind) {
                return findingPriority($0.kind) < findingPriority($1.kind)
            }
            return $0.signingIdentifier.localizedCaseInsensitiveCompare($1.signingIdentifier) == .orderedAscending
        }
        return Report(findings: findings, inspectedRuleCount: rules.count)
    }

    private static func findingPriority(_ kind: FindingKind) -> Int {
        switch kind {
        case .excessivePrivacyRecords: 0
        case .installedApplicationDenied: 1
        case .conflictingPrivacyDecisions: 2
        case .stalePrivacyRecords: 3
        }
    }

    private static func resolveString(_ reference: Any?, objects: [Any]) -> String? {
        guard let reference else { return nil }
        if let value = reference as? String { return value }
        guard let index = keyedArchiveIndex(reference), objects.indices.contains(index) else { return nil }
        return objects[index] as? String
    }

    /// `PropertyListSerialization` exposes keyed-archive references as an
    /// opaque Core Foundation UID. Re-serializing that single inert value to
    /// XML is a public-API way to obtain its `CF$UID` integer without linking
    /// private `CFKeyedArchiverUID*` symbols or parsing runtime descriptions.
    private static func keyedArchiveIndex(_ reference: Any) -> Int? {
        guard let xml = try? PropertyListSerialization.data(
            fromPropertyList: ["reference": reference],
            format: .xml,
            options: 0
        ), let text = String(data: xml, encoding: .utf8) else {
            return nil
        }
        let pattern = #"<key>CF\$UID</key>\s*<integer>(\d+)</integer>"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
    }
}
