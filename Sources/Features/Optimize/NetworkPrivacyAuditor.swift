import Foundation
import CryptoKit

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
        case none
    }

    public struct Finding: Identifiable, Hashable, Sendable {
        public let kind: FindingKind
        public let severity: Severity
        public let signingIdentifier: String
        public let affectedRecordCount: Int
        public let remediation: Remediation
        public let detail: String
        /// A stable digest of the exact records behind this finding. Ignoring
        /// one observation must not hide new paths or changed decisions.
        public let evidenceFingerprint: String

        public var id: String {
            "\(kind.rawValue):\(signingIdentifier)"
        }
    }

    public struct Report: Hashable, Sendable {
        public let findings: [Finding]
        public let inspectedRuleCount: Int
        public var ignoredFindings: [Finding] = []

        public var autoFixableCount: Int {
            findings.count { $0.remediation == .automatic }
        }

        public var issueCount: Int {
            findings.count { $0.severity > .information }
        }

        public var informationalCount: Int {
            findings.count { $0.severity == .information }
        }

        public var requiresGuidedRepair: Bool {
            findings.contains { $0.severity > .information && $0.remediation == .guidedRecovery }
        }

        public var summary: String {
            if issueCount > 0 {
                return "\(issueCount) issue\(issueCount == 1 ? " needs" : "s need") review in Local Network settings"
            }
            if informationalCount > 0 {
                return "\(informationalCount) informational item\(informationalCount == 1 ? "" : "s") — no repair needed"
            }
            if !ignoredFindings.isEmpty {
                return "No issues found — \(ignoredFindings.count) informational item\(ignoredFindings.count == 1 ? "" : "s") ignored"
            }
            return "No Local Network privacy issues found"
        }

        public var isHealthy: Bool {
            issueCount == 0
        }
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
        findingStore: NetworkPrivacyFindingStore = .shared,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> Report {
        let report = try audit(
            rules: loadRules(from: archiveURL),
            installedApplications: installedApplications,
            fileExists: fileExists
        )
        return findingStore.applyingIgnores(to: report)
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

    /// Missing executables are historical metadata. Only current records are
    /// considered for excessive records or conflicting privacy decisions.
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
            let stale = appRules.filter { rule in
                guard let path = rule.executablePath, path != "$null" else { return false }
                return !fileExists(path)
            }
            let staleRules = Set(stale)
            let currentRules = appRules.filter { !staleRules.contains($0) }
            if currentRules.count > 10 {
                findings.append(Finding(
                    kind: .excessivePrivacyRecords,
                    severity: .critical,
                    signingIdentifier: signingIdentifier,
                    affectedRecordCount: currentRules.count,
                    remediation: .guidedRecovery,
                    detail: "\(currentRules.count) current Local Network records found. "
                        + "Review settings if this app has connection problems.",
                    evidenceFingerprint: fingerprint(currentRules)
                ))
            }

            if !stale.isEmpty {
                findings.append(Finding(
                    kind: .stalePrivacyRecords,
                    severity: .information,
                    signingIdentifier: signingIdentifier,
                    affectedRecordCount: stale.count,
                    remediation: .none,
                    detail: "\(stale.count) historical record\(stale.count == 1 ? " refers" : "s refer") "
                        + "to executables that no longer exist. "
                        + "App updates can leave these behind. No repair is needed for these records alone.",
                    evidenceFingerprint: fingerprint(stale)
                ))
            }

            if Set(currentRules.map(\.isDenied)).count > 1 {
                findings.append(Finding(
                    kind: .conflictingPrivacyDecisions,
                    severity: .critical,
                    signingIdentifier: signingIdentifier,
                    affectedRecordCount: currentRules.count,
                    remediation: .guidedRecovery,
                    detail: "Current Local Network records disagree about whether this app is allowed. "
                        + "Review its access in System Settings.",
                    evidenceFingerprint: fingerprint(currentRules)
                ))
            }

            let installed = installedByBundleID[signingIdentifier] ?? []
            let installedDenied = currentRules.filter { rule in
                guard rule.isDenied else { return false }
                guard let path = rule.executablePath, path != "$null" else {
                    return !installed.isEmpty
                }
                return installed.contains { $0.executablePath == path }
            }
            if !installedDenied.isEmpty {
                findings.append(Finding(
                    kind: .installedApplicationDenied,
                    severity: .information,
                    signingIdentifier: signingIdentifier,
                    affectedRecordCount: installedDenied.count,
                    remediation: .manual,
                    detail: "Local Network access is turned off for this app. This is a valid privacy choice. "
                        + "Change it in System Settings only if you want the app to access your local network.",
                    evidenceFingerprint: fingerprint(installedDenied)
                ))
            }
        }

        findings.sort {
            if $0.severity != $1.severity {
                return $0.severity > $1.severity
            }
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

    private static func fingerprint(_ rules: [Rule]) -> String {
        // Length prefixes keep arbitrary paths unambiguous. Sorting makes the
        // digest independent of archive order while preserving duplicate counts.
        let records = rules.map { rule in
            [rule.signingIdentifier, rule.executablePath ?? "$null", String(rule.isDenied), String(rule.preferenceWasSet)]
                .map { "\($0.utf8.count):\($0)" }.joined()
        }.sorted()
        return SHA256.hash(data: Data(records.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func resolveString(_ reference: Any?, objects: [Any]) -> String? {
        guard let reference else { return nil }
        if let value = reference as? String {
            return value
        }
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
