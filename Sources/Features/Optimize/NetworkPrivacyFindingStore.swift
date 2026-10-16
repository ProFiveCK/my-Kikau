import Foundation
import Core

/// Remembers acknowledgments in myKikau's own preferences. It never changes
/// macOS privacy decisions, and only informational findings can be ignored.
public final class NetworkPrivacyFindingStore: @unchecked Sendable {
    public static let shared = NetworkPrivacyFindingStore()

    private let injectedDefaults: UserDefaults?
    private let lock = NSLock()
    private var defaults: UserDefaults {
        injectedDefaults ?? AppDefaults.store
    }

    public init(defaults: UserDefaults? = nil) {
        injectedDefaults = defaults
    }

    public func ignore(_ finding: NetworkPrivacyAuditor.Finding) {
        guard finding.severity == .information else { return }
        lock.lock()
        defer { lock.unlock() }
        var ignored = savedFingerprints
        ignored[finding.id] = finding.evidenceFingerprint
        defaults.set(ignored, forKey: AppStorageKey.networkPrivacyIgnoredFindings)
    }

    public func restore(_ finding: NetworkPrivacyAuditor.Finding) {
        lock.lock()
        defer { lock.unlock() }
        var ignored = savedFingerprints
        ignored.removeValue(forKey: finding.id)
        defaults.set(ignored, forKey: AppStorageKey.networkPrivacyIgnoredFindings)
    }

    public func applyingIgnores(to report: NetworkPrivacyAuditor.Report) -> NetworkPrivacyAuditor.Report {
        lock.lock()
        let ignored = savedFingerprints
        lock.unlock()
        let allFindings = report.findings + report.ignoredFindings
        let isIgnored: (NetworkPrivacyAuditor.Finding) -> Bool = {
            $0.severity == .information && ignored[$0.id] == $0.evidenceFingerprint
        }
        var result = NetworkPrivacyAuditor.Report(
            findings: allFindings.filter { !isIgnored($0) },
            inspectedRuleCount: report.inspectedRuleCount
        )
        result.ignoredFindings = allFindings.filter(isIgnored)
        return result
    }

    private var savedFingerprints: [String: String] {
        defaults.dictionary(forKey: AppStorageKey.networkPrivacyIgnoredFindings) as? [String: String] ?? [:]
    }
}
