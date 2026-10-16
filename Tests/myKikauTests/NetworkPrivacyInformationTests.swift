import Foundation
import Testing
import Core
@testable import Features

@Suite("Network privacy information")
struct NetworkPrivacyInformationTests {
    private let installedPath = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"

    private func report(clonePaths: [String] = ["/missing/clone1", "/missing/clone2", "/missing/clone3"]) -> NetworkPrivacyAuditor.Report {
        let rules = [NetworkPrivacyAuditor.Rule(
            signingIdentifier: "com.openai.codex", executablePath: installedPath,
            isDenied: true, preferenceWasSet: true
        )] + clonePaths.map {
            NetworkPrivacyAuditor.Rule(
                signingIdentifier: "com.google.Chrome", executablePath: $0,
                isDenied: false, preferenceWasSet: true
            )
        }
        return NetworkPrivacyAuditor.audit(
            rules: rules,
            installedApplications: [.init(bundleIdentifier: "com.openai.codex", executablePath: installedPath)],
            fileExists: { $0 == installedPath }
        )
    }

    @Test("the reported Codex denial and three Chrome clones need no repair")
    func screenshotScenarioIsInformation() {
        let report = report()
        #expect(report.findings.count == 2)
        #expect(report.informationalCount == 2)
        #expect(report.issueCount == 0)
        #expect(report.isHealthy)
        #expect(report.autoFixableCount == 0)
        #expect(!report.requiresGuidedRepair)
        #expect(report.findings.first { $0.kind == .stalePrivacyRecords }?.affectedRecordCount == 3)
        #expect(MaintenanceRunner().networkPrivacyOutcome(for: report) == .information(report.summary))
        #expect(!report.summary.contains("guided repair"))
    }

    @Test("ignores survive a new store and defaults instance, and restore takes effect immediately")
    func persistsAndRestores() throws {
        let suite = "myKikau.privacy-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let report = report()
        let store = NetworkPrivacyFindingStore(defaults: defaults)
        for finding in report.findings { store.ignore(finding) }

        let reopened = NetworkPrivacyFindingStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let ignored = reopened.applyingIgnores(to: self.report())
        #expect(ignored.findings.isEmpty)
        #expect(ignored.ignoredFindings.count == 2)
        #expect(ignored.issueCount == 0)
        #expect(!ignored.requiresGuidedRepair)
        #expect(MaintenanceRunner().networkPrivacyOutcome(for: ignored) == .unchanged(ignored.summary))

        reopened.restore(try #require(ignored.ignoredFindings.first))
        let restored = store.applyingIgnores(to: ignored)
        #expect(restored.findings.count == 1)
        #expect(restored.ignoredFindings.count == 1)
        #expect(MaintenanceRunner().networkPrivacyOutcome(for: restored) == .information(restored.summary))
    }

    @Test("new paths reappear even when the finding kind, bundle ID, and record count stay the same")
    func changedEvidenceReappears() throws {
        let suite = "myKikau.privacy-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NetworkPrivacyFindingStore(defaults: defaults)
        let original = report()
        for finding in original.findings { store.ignore(finding) }

        let changed = store.applyingIgnores(to: report(clonePaths: ["/missing/clone1", "/missing/clone2", "/missing/new-clone"]))
        #expect(changed.findings.map(\.kind) == [.stalePrivacyRecords])
        #expect(changed.ignoredFindings.map(\.kind) == [.installedApplicationDenied])

        let reordered = store.applyingIgnores(to: report(clonePaths: ["/missing/clone3", "/missing/clone1", "/missing/clone2"]))
        #expect(reordered.findings.isEmpty)
        #expect(reordered.ignoredFindings.count == 2)
    }

    @Test("changed historical decisions, counts, and app identities are not hidden")
    func changesAreNotIgnored() throws {
        let suite = "myKikau.privacy-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NetworkPrivacyFindingStore(defaults: defaults)
        let original = NetworkPrivacyAuditor.Rule(
            signingIdentifier: "com.google.Chrome", executablePath: "/missing/clone",
            isDenied: false, preferenceWasSet: true
        )
        let initial = NetworkPrivacyAuditor.audit(rules: [original], installedApplications: [], fileExists: { _ in false })
        store.ignore(try #require(initial.findings.first))
        let alternatives = [
            [NetworkPrivacyAuditor.Rule(
                signingIdentifier: original.signingIdentifier, executablePath: original.executablePath,
                isDenied: true, preferenceWasSet: true
            )],
            [original, original],
            [NetworkPrivacyAuditor.Rule(
                signingIdentifier: "com.google.Chrome.other", executablePath: original.executablePath,
                isDenied: false, preferenceWasSet: true
            )],
        ]
        for rules in alternatives {
            let current = NetworkPrivacyAuditor.audit(rules: rules, installedApplications: [], fileExists: { _ in false })
            #expect(store.applyingIgnores(to: current).findings.count == 1)
        }
    }

    @Test("many missing Chrome clones with mixed old permissions remain information")
    func historicalClonesDoNotTriggerRecoveryIndirectly() {
        let rules = (0..<20).map {
            NetworkPrivacyAuditor.Rule(
                signingIdentifier: "com.google.Chrome", executablePath: "/missing/code_sign_clone/\($0)",
                isDenied: $0.isMultiple(of: 2), preferenceWasSet: true
            )
        } + [.init(signingIdentifier: "com.google.Chrome", executablePath: nil, isDenied: false, preferenceWasSet: true)]
        let report = NetworkPrivacyAuditor.audit(rules: rules, installedApplications: [], fileExists: { _ in false })
        #expect(report.findings.map(\.kind) == [.stalePrivacyRecords])
        #expect(report.issueCount == 0)
        #expect(!report.requiresGuidedRepair)
    }
}
