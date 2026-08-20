import Testing
import Core
@testable import Features
import Foundation

@Suite("MaintenanceRunner")
struct MaintenanceRunnerTests {
    private func makeHome() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func touch(_ url: URL, size: Int = 8) {
        makeDir(url.deletingLastPathComponent())
        try? Data(count: size).write(to: url)
    }

    /// `OperationLog.append` writes fire-and-forget on its own queue, so poll
    /// briefly for the entry to land before relying on it being readable —
    /// same pattern as `runLogsToOperationLog` below.
    private func waitForLogEntry(_ opLog: OperationLog, action: String) async {
        for _ in 0..<50 {
            if opLog.recent(limit: 10).contains(where: { $0.action == action }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    private func setModDate(_ url: URL, daysAgo: Int) {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86400)
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Command builders (pure, no process spawning)

    @Test("launchServicesCommands returns lsregister -gc and rescan")
    func launchServicesCommandsShape() {
        let runner = MaintenanceRunner()
        let commands = runner.launchServicesCommands()
        // On a real macOS system, lsregister exists. On CI without the framework
        // path, this may be empty — so only assert shape when non-empty.
        if !commands.isEmpty {
            #expect(commands.count == 2)
            #expect(commands[0].1 == ["-gc"])
            #expect(commands[1].1.contains("-r"))
        }
    }

    @Test("preventDSStoreCommands covers network and USB keys")
    func preventDSStoreCommandsShape() {
        let runner = MaintenanceRunner()
        let keys = runner.preventDSStoreCommands()
        #expect(keys.count == 2)
        #expect(keys.contains { $0.key == "DSDontWriteNetworkStores" })
        #expect(keys.contains { $0.key == "DSDontWriteUSBStores" })
        #expect(keys.allSatisfy { $0.domain == "com.apple.desktopservices" })
    }

    @Test("legacyOverrideKeys includes App Nap and disk-image keys")
    func legacyOverrideKeysShape() {
        let runner = MaintenanceRunner()
        let keys = runner.legacyOverrideKeys()
        #expect(keys.count == 4)
        #expect(keys.contains { $0.key == "NSAppSleepDisabled" })
        #expect(keys.contains { $0.key == "skip-verify" })
        #expect(keys.contains { $0.key == "skip-verify-locked" })
        #expect(keys.contains { $0.key == "skip-verify-remote" })
    }

    @Test("quarantineDBPath resolves under the injected home")
    func quarantineDBPathUnderHome() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = MaintenanceRunner(home: home)
        let path = runner.quarantineDBPath()
        #expect(path.path.contains(home.path))
        #expect(path.lastPathComponent == "com.apple.LaunchServices.QuarantineEventsV2")
    }

    // MARK: - Dry-run

    @Test("runProcess in dry-run returns synthetic success without spawning")
    func runProcessDryRunNoSpawn() async {
        let runner = MaintenanceRunner()
        let (code, output) = await runner.runProcess(
            "/bin/echo", arguments: ["hello"], dryRun: true)
        #expect(code == 0)
        #expect(output.contains("[dry-run]"))
        #expect(output.contains("/bin/echo"))
    }

    // MARK: - Sudo

    @Test("sudo tasks return skipped in this phase")
    func sudoTasksSkipped() async {
        let runner = MaintenanceRunner()
        let sudoTasks = ["dns_spotlight", "network_cache", "network_stack",
                         "disk_permissions", "spotlight_index", "periodic", "disk_verify"]
        for id in sudoTasks {
            let result = await runner.run(taskID: id, dryRun: false)
            if case .skipped = result.outcome {
                // expected
            } else {
                Issue.record("Expected .skipped for sudo task \(id), got \(result.outcome)")
            }
        }
    }

    @Test("deferred complex tasks return unavailable")
    func deferredTasksUnavailable() async {
        let runner = MaintenanceRunner()
        let deferred = ["sqlite_vacuum", "notifications", "coreduet", "login_items"]
        for id in deferred {
            let result = await runner.run(taskID: id, dryRun: false)
            if case .unavailable = result.outcome {
                // expected
            } else {
                Issue.record("Expected .unavailable for \(id), got \(result.outcome)")
            }
        }
    }

    @Test("unknown task ID returns failed")
    func unknownTaskFails() async {
        let runner = MaintenanceRunner()
        let result = await runner.run(taskID: "nonexistent_task", dryRun: true)
        if case .failed = result.outcome {
            // expected
        } else {
            Issue.record("Expected .failed for unknown task, got \(result.outcome)")
        }
    }

    // MARK: - saved_state

    @Test("saved_state removes old savedState dirs via SafeFileDeleter")
    func savedStateRemovesOld() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let stateDir = home.appendingPathComponent("Library/Saved Application State")
        let old = stateDir.appendingPathComponent("com.old.app.savedState")
        makeDir(old)
        touch(old.appendingPathComponent("state.txt"), size: 10)
        setModDate(old, daysAgo: 60)

        let recent = stateDir.appendingPathComponent("com.recent.app.savedState")
        makeDir(recent)
        touch(recent.appendingPathComponent("state.txt"), size: 10)
        setModDate(recent, daysAgo: 1)

        let deleter = SafeFileDeleter()
        let runner = MaintenanceRunner(home: home, deleter: deleter)
        let result = await runner.run(taskID: "saved_state", dryRun: false)

        if case .applied = result.outcome {
            // expected
        } else {
            Issue.record("Expected .applied for saved_state, got \(result.outcome)")
        }
        // Old state should be gone, recent should remain.
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    @Test("saved_state dry-run reports would-remove without deleting")
    func savedStateDryRun() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let stateDir = home.appendingPathComponent("Library/Saved Application State")
        let old = stateDir.appendingPathComponent("com.old.app.savedState")
        makeDir(old)
        touch(old.appendingPathComponent("state.txt"), size: 10)
        setModDate(old, daysAgo: 60)

        let deleter = SafeFileDeleter()
        let runner = MaintenanceRunner(home: home, deleter: deleter)
        let result = await runner.run(taskID: "saved_state", dryRun: true)

        if case .applied = result.outcome {
            // expected
        } else {
            Issue.record("Expected .applied (dry-run) for saved_state, got \(result.outcome)")
        }
        // Dry-run must not delete.
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test("saved_state unchanged when no old states")
    func savedStateUnchangedWhenNone() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let stateDir = home.appendingPathComponent("Library/Saved Application State")
        let recent = stateDir.appendingPathComponent("com.recent.app.savedState")
        makeDir(recent)
        setModDate(recent, daysAgo: 1)

        let deleter = SafeFileDeleter()
        let runner = MaintenanceRunner(home: home, deleter: deleter)
        let result = await runner.run(taskID: "saved_state", dryRun: false)

        if case .unchanged = result.outcome {
            // expected
        } else {
            Issue.record("Expected .unchanged for saved_state with no old states, got \(result.outcome)")
        }
    }

    // MARK: - launch_agents

    @Test("launch_agents detects broken plist pointing at missing binary")
    func launchAgentsDetectsBroken() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(agentsDir)

        // Broken: Program points at a nonexistent binary.
        let brokenPlist = agentsDir.appendingPathComponent("com.broken.agent.plist")
        let brokenDict: NSDictionary = [
            "Program": "/usr/local/nonexistent/binary",
            "Label": "com.broken.agent",
        ]
        brokenDict.write(to: brokenPlist, atomically: true)

        // Healthy: Program points at a real binary.
        let okPlist = agentsDir.appendingPathComponent("com.ok.agent.plist")
        let okDict: NSDictionary = [
            "Program": "/bin/echo",
            "Label": "com.ok.agent",
        ]
        okDict.write(to: okPlist, atomically: true)

        let deleter = SafeFileDeleter()
        let runner = MaintenanceRunner(home: home, deleter: deleter)
        let result = await runner.run(taskID: "launch_agents", dryRun: true)

        if case .applied = result.outcome {
            // expected — would remove the broken one
        } else {
            Issue.record("Expected .applied for launch_agents with a broken plist, got \(result.outcome)")
        }
        // Dry-run must not delete either plist.
        #expect(FileManager.default.fileExists(atPath: brokenPlist.path))
        #expect(FileManager.default.fileExists(atPath: okPlist.path))
    }

    @Test("launch_agents unchanged when all healthy")
    func launchAgentsUnchangedWhenHealthy() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(agentsDir)
        let okPlist = agentsDir.appendingPathComponent("com.ok.agent.plist")
        let okDict: NSDictionary = [
            "Program": "/bin/echo",
            "Label": "com.ok.agent",
        ]
        okDict.write(to: okPlist, atomically: true)

        let runner = MaintenanceRunner(home: home)
        let result = await runner.run(taskID: "launch_agents", dryRun: true)

        if case .unchanged = result.outcome {
            // expected
        } else {
            Issue.record("Expected .unchanged for healthy launch_agents, got \(result.outcome)")
        }
    }

    // MARK: - quarantine

    @Test("quarantine unchanged when database not present")
    func quarantineUnchangedWhenAbsent() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let runner = MaintenanceRunner(home: home)
        let result = await runner.run(taskID: "quarantine", dryRun: false)

        if case .unchanged = result.outcome {
            // expected
        } else {
            Issue.record("Expected .unchanged when no quarantine DB, got \(result.outcome)")
        }
    }

    // MARK: - Staleness gating (finder_cache, launch_services)

    @Test("finder_cache dry-run reports unchanged shortly after a real refresh")
    func finderCacheUnchangedWhenRecentlyRun() async {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".log")
        let opLog = OperationLog(logURL: logURL, enabled: true)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let runner = MaintenanceRunner(opLog: opLog)
        // A real (non-dry-run) run only succeeds if qlmanage exists — skip
        // the assertion on hosts where it doesn't (e.g. non-macOS CI).
        let real = await runner.run(taskID: "finder_cache", dryRun: false)
        guard case .applied = real.outcome else { return }
        await waitForLogEntry(opLog, action: "optimize.finder_cache")

        let scan = await runner.run(taskID: "finder_cache", dryRun: true)
        if case .unchanged = scan.outcome {
            // expected — recommendation gated by recent success
        } else {
            Issue.record("Expected .unchanged for finder_cache right after a real run, got \(scan.outcome)")
        }
    }

    @Test("launch_services dry-run reports unchanged shortly after a real repair")
    func launchServicesUnchangedWhenRecentlyRun() async {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".log")
        let opLog = OperationLog(logURL: logURL, enabled: true)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let runner = MaintenanceRunner(opLog: opLog)
        let real = await runner.run(taskID: "launch_services", dryRun: false)
        guard case .applied = real.outcome else { return }
        await waitForLogEntry(opLog, action: "optimize.launch_services")

        let scan = await runner.run(taskID: "launch_services", dryRun: true)
        if case .unchanged = scan.outcome {
            // expected — recommendation gated by recent success
        } else {
            Issue.record("Expected .unchanged for launch_services right after a real run, got \(scan.outcome)")
        }
    }

    // MARK: - run(taskIDs:)

    @Test("run(taskIDs:) returns a result for every requested ID")
    func runMultipleReturnsAll() async {
        let runner = MaintenanceRunner()
        let ids = ["sqlite_vacuum", "dns_spotlight", "login_items"]
        let results = await runner.run(taskIDs: ids, dryRun: true)
        #expect(results.count == ids.count)
        for id in ids {
            #expect(results[id] != nil)
        }
    }

    // MARK: - OperationLog integration

    @Test("run logs an entry to OperationLog")
    func runLogsToOperationLog() async {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".log")
        let opLog = OperationLog(logURL: logURL, enabled: true)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let runner = MaintenanceRunner(opLog: opLog)
        _ = await runner.run(taskID: "sqlite_vacuum", dryRun: true)

        // OperationLog.append is async (fire-and-forget via DispatchQueue),
        // so poll briefly for the entry to appear.
        var entries: [OperationLog.Entry] = []
        for _ in 0..<20 {
            entries = opLog.recent(limit: 10)
            if !entries.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        #expect(entries.count == 1)
        #expect(entries.first?.action == "optimize.sqlite_vacuum")
        #expect(entries.first?.dryRun == true)
    }
}