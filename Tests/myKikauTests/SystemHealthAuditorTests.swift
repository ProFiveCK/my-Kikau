import Foundation
import Testing
@testable import Features

@Suite("SystemHealthAuditor")
struct SystemHealthAuditorTests {
    @Test("more than ten privacy records for one app is an unhealthy guided-repair finding")
    func excessivePrivacyRecordsRequireGuidedRepair() {
        let rules = (0..<11).map { index in
            NetworkPrivacyAuditor.Rule(
                signingIdentifier: "com.google.Chrome",
                executablePath: "/private/var/folders/test/com.google.Chrome.code_sign_clone/clone.\(index)/Google Chrome",
                isDenied: index == 0,
                preferenceWasSet: true
            )
        }

        let report = NetworkPrivacyAuditor.audit(
            rules: rules,
            installedApplications: [
                .init(
                    bundleIdentifier: "com.google.Chrome",
                    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                ),
            ],
            fileExists: { $0.hasPrefix("/Applications/") }
        )

        let finding = report.findings.first
        #expect(finding?.kind == .excessivePrivacyRecords)
        #expect(finding?.severity == .critical)
        #expect(finding?.affectedRecordCount == 11)
        #expect(finding?.remediation == .guidedRecovery)
        #expect(report.autoFixableCount == 0)
    }

    @Test("stale conflicting rules and a denied installed app are reported")
    func staleConflictingDeniedRulesAreUnhealthy() {
        let installedPath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let rules = [
            NetworkPrivacyAuditor.Rule(
                signingIdentifier: "com.google.Chrome",
                executablePath: installedPath,
                isDenied: true,
                preferenceWasSet: true
            ),
            NetworkPrivacyAuditor.Rule(
                signingIdentifier: "com.google.Chrome",
                executablePath: "/private/var/folders/test/code_sign_clone.old/Google Chrome",
                isDenied: false,
                preferenceWasSet: true
            ),
        ]

        let report = NetworkPrivacyAuditor.audit(
            rules: rules,
            installedApplications: [
                .init(bundleIdentifier: "com.google.Chrome", executablePath: installedPath),
            ],
            fileExists: { $0 == installedPath }
        )

        #expect(report.findings.contains { $0.kind == .installedApplicationDenied })
        #expect(report.findings.contains { $0.kind == .conflictingPrivacyDecisions })
        #expect(report.findings.contains {
            $0.kind == .stalePrivacyRecords && $0.affectedRecordCount == 1
        })
        #expect(report.findings.allSatisfy { $0.remediation == .guidedRecovery })
        #expect(report.autoFixableCount == 0)
    }

    @Test("keyed Network Extension archive decodes path-controller rules")
    func keyedArchiveDecodesRules() throws {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".plist")
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>$archiver</key><string>NSKeyedArchiver</string>
          <key>$version</key><integer>100000</integer>
          <key>$objects</key>
          <array>
            <string>$null</string>
            <dict>
              <key>$class</key><dict><key>CF$UID</key><integer>2</integer></dict>
              <key>Path</key><dict><key>CF$UID</key><integer>3</integer></dict>
              <key>SigningIdentifier</key><dict><key>CF$UID</key><integer>4</integer></dict>
              <key>DenyMulticast</key><false/>
              <key>MulticastPreferenceSet</key><true/>
            </dict>
            <dict><key>$classname</key><string>NEPathRule</string></dict>
            <string>/private/var/folders/test/code_sign_clone.old/Google Chrome</string>
            <string>com.google.Chrome</string>
          </array>
          <key>$top</key><dict><key>root</key><dict><key>CF$UID</key><integer>1</integer></dict></dict>
        </dict>
        </plist>
        """
        try Data(xml.utf8).write(to: archiveURL)

        let rules = try NetworkPrivacyAuditor.loadRules(from: archiveURL)

        #expect(rules == [
            .init(
                signingIdentifier: "com.google.Chrome",
                executablePath: "/private/var/folders/test/code_sign_clone.old/Google Chrome",
                isDenied: false,
                preferenceWasSet: true
            ),
        ])

        let report = try NetworkPrivacyAuditor.inspect(
            archiveURL: archiveURL,
            installedApplications: [],
            fileExists: { _ in false }
        )
        #expect(report.findings.contains { $0.kind == .stalePrivacyRecords })
    }

    @Test("installed app discovery returns exact bundle ID and executable path")
    func discoversInstalledApplications() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Applications/Example.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Example")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        let info: NSDictionary = [
            "CFBundleIdentifier": "com.example.App",
            "CFBundleExecutable": "Example",
        ]
        #expect(info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = NetworkPrivacyAuditor.discoverInstalledApplications(
            in: [root.appendingPathComponent("Applications")]
        )

        #expect(installed == [
            .init(bundleIdentifier: "com.example.App", executablePath: executable.path),
        ])
    }

    @Test("network privacy audit is catalogued as guided and never auto-fixable")
    func catalogMarksNetworkPrivacyAsGuided() throws {
        let task = try #require(MaintenanceCatalog.tasks.first { $0.id == "network_privacy" })
        #expect(task.kind == .guidedDiagnostic)
        #expect(task.safeForAuto == false)
        #expect(task.requiresSudo == false)
    }

    @Test("maintenance runner maps unhealthy privacy report to attention")
    func runnerMapsPrivacyFindingsToAttention() {
        let rules = (0..<11).map {
            NetworkPrivacyAuditor.Rule(
                signingIdentifier: "com.google.Chrome",
                executablePath: "/missing/Chrome-\($0)",
                isDenied: false,
                preferenceWasSet: true
            )
        }
        let report = NetworkPrivacyAuditor.audit(
            rules: rules,
            installedApplications: [],
            fileExists: { _ in false }
        )

        let outcome = MaintenanceRunner().networkPrivacyOutcome(for: report)

        guard case .attention(let detail) = outcome else {
            Issue.record("Expected attention, got \(outcome)")
            return
        }
        #expect(detail?.contains("2 issues") == true)
        #expect(detail?.contains("guided repair") == true)
    }

    @Test("guided repair preparation copies files and writes checksums and Recovery instructions")
    func preparesGuidedRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Library/Preferences")
        let destination = root.appendingPathComponent("Repairs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let main = source.appendingPathComponent("com.apple.networkextension.plist")
        let cache = source.appendingPathComponent("com.apple.networkextension.uuidcache.plist")
        try Data("main-store".utf8).write(to: main)
        try Data("uuid-cache".utf8).write(to: cache)
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try NetworkPrivacyRepairAssistant.prepare(
            sourceFiles: [main, cache],
            destinationRoot: destination,
            date: Date(timeIntervalSince1970: 0)
        )

        #expect(prepared.copiedFiles.count == 2)
        #expect(FileManager.default.fileExists(atPath: prepared.checksumsURL.path))
        #expect(FileManager.default.fileExists(atPath: prepared.instructionsURL.path))
        let checksums = try String(contentsOf: prepared.checksumsURL, encoding: .utf8)
        let instructions = try String(contentsOf: prepared.instructionsURL, encoding: .utf8)
        #expect(checksums.contains("com.apple.networkextension.plist"))
        #expect(checksums.contains("com.apple.networkextension.uuidcache.plist"))
        #expect(instructions.contains("csrutil disable"))
        #expect(instructions.contains("csrutil enable"))
    }
}
