import Testing
@testable import Core
import Foundation

@Suite("OperationLog")
struct OperationLogTests {
    private func makeDir() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func entry(_ path: String, size: Int64 = 10, outcome: OperationLog.Outcome = .success, dryRun: Bool = false) -> OperationLog.Entry {
        .init(action: "test", path: path, sizeBytes: size, mode: .trash, outcome: outcome, dryRun: dryRun)
    }

    @Test("Entries come back newest first and the chain verifies")
    func appendReadVerify() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(logURL: dir.appendingPathComponent("operations.log"))
        for index in 0..<5 { log.append(entry("/tmp/file\(index)")) }

        let recent = log.recent(limit: 3)
        #expect(recent.map(\.path) == ["/tmp/file4", "/tmp/file3", "/tmp/file2"])

        let status = log.verifyChain()
        #expect(status.isIntact)
        #expect(status.verified == 4)   // every line after the first
        #expect(status.unchained == 1)
    }

    @Test("Editing a line breaks the chain at the line after it")
    func tamperingIsDetected() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        let log = OperationLog(logURL: url)
        for index in 0..<4 { log.append(entry("/tmp/file\(index)")) }
        log.flush()

        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "/tmp/file1", with: "/tmp/other")
        try text.write(to: url, atomically: true, encoding: .utf8)

        // A fresh instance, as a later launch would be.
        let status = OperationLog(logURL: url).verifyChain()
        #expect(status.isIntact == false)
        #expect(status.firstBrokenLine == 3)
    }

    @Test("Removing a line breaks the chain")
    func deletionIsDetected() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        let log = OperationLog(logURL: url)
        for index in 0..<4 { log.append(entry("/tmp/file\(index)")) }
        log.flush()

        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.remove(at: 1)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        #expect(OperationLog(logURL: url).verifyChain().isIntact == false)
    }

    @Test("Removing the newest entries is detected")
    func tailTruncationIsDetected() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        let log = OperationLog(logURL: url)
        for index in 0..<6 { log.append(entry("/tmp/file\(index)")) }
        log.flush()

        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.removeLast(2)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let status = OperationLog(logURL: url).verifyChain()
        #expect(status.truncated)
        #expect(status.isIntact == false)
    }

    @Test("Removing the oldest entries is detected")
    func headTruncationIsDetected() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        let log = OperationLog(logURL: url)
        for index in 0..<6 { log.append(entry("/tmp/file\(index)")) }
        log.flush()

        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.removeFirst(2)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let status = OperationLog(logURL: url).verifyChain()
        #expect(status.truncated)
        #expect(status.isIntact == false)
    }

    @Test("The chain is checked across a rotation, and a missing rotated file is noticed")
    func chainSpansRotation() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        let log = OperationLog(logURL: url, enabled: true, persistsEnabled: false, maxFileBytes: 400)
        for index in 0..<8 { log.append(entry("/tmp/file\(index)")) }
        log.flush()
        let rotated = dir.appendingPathComponent("operations.1.log")
        #expect(FileManager.default.fileExists(atPath: rotated.path))

        // Intact: the current file's first entry links to the rotated file's last.
        #expect(log.verifyChain().isIntact)

        // Edit the rotated file's last line: the link no longer matches.
        var text = try String(contentsOf: rotated, encoding: .utf8)
        let lastPath = try #require(text.split(separator: "\n").last.map(String.init))
        text = text.replacingOccurrences(of: lastPath, with: lastPath.replacingOccurrences(of: "/tmp/file", with: "/tmp/edit"))
        try text.write(to: rotated, atomically: true, encoding: .utf8)
        #expect(OperationLog(logURL: url, enabled: true, persistsEnabled: false, maxFileBytes: 400).verifyChain().firstBrokenLine == 1)

        // Remove it altogether: earlier entries are missing.
        try FileManager.default.removeItem(at: rotated)
        #expect(OperationLog(logURL: url, enabled: true, persistsEnabled: false, maxFileBytes: 400).verifyChain().truncated)
    }

    @Test("recent(limit:) returns exactly `limit` entries even when a read boundary lands on a line boundary")
    func tailReadIsExact() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        let log = OperationLog(logURL: url)
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        func fixed(_ path: String) -> OperationLog.Entry {
            .init(timestamp: stamp, action: "test", path: path, sizeBytes: 10, mode: .trash, outcome: .success, dryRun: false)
        }
        // Learn the length of a chained line, then pad every line to exactly
        // 512 bytes so the 64 KB read chunks end precisely on line boundaries.
        log.append(fixed("/tmp/a"))
        log.append(fixed("/tmp/b"))
        log.flush()
        let probe = try Data(contentsOf: url).split(separator: 0x0A)
        let padding = 512 - (probe[1].count + 1)
        try #require(padding > 0)
        let path = "/tmp/b" + String(repeating: "x", count: padding)
        for _ in 0..<400 { log.append(fixed(path)) }
        log.flush()
        let lengths = Set(try Data(contentsOf: url).split(separator: 0x0A).dropFirst(2).map(\.count))
        try #require(lengths == [511])

        for limit in [1, 63, 64, 65, 127, 128, 129, 300] {
            #expect(log.recent(limit: limit).count == limit, "limit \(limit)")
        }
        #expect(log.verifyChain().isIntact)
    }

    @Test("Totals count only real successes and survive rotation")
    func totalsSurviveRotation() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        // Tiny limit so a handful of entries forces several rotations.
        let log = OperationLog(logURL: url, enabled: true, persistsEnabled: false, maxFileBytes: 400)
        for index in 0..<12 { log.append(entry("/tmp/file\(index)", size: 100)) }
        log.append(entry("/tmp/dry", size: 999, outcome: .dryRun, dryRun: true))
        log.append(entry("/tmp/failed", size: 999, outcome: .failed))

        #expect(log.totals().freedBytes == 1200)
        #expect(log.totals().operations == 14)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("operations.1.log").path))
        // The current file holds fewer than everything written.
        #expect(log.recent(limit: 100).count < 14)
        #expect(log.verifyChain().isIntact)
    }

    @Test("The log folder is recreated if it disappears while the app is running")
    func recreatesMissingFolder() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logDir = dir.appendingPathComponent("Logs/myKikau")
        let log = OperationLog(logURL: logDir.appendingPathComponent("operations.log"))
        log.append(entry("/tmp/before"))
        log.flush()
        try? FileManager.default.removeItem(at: logDir)

        log.append(entry("/tmp/after"))

        #expect(log.recent(limit: 5).map(\.path) == ["/tmp/after"])
    }

    @Test("Disabled logs write nothing")
    func disabledWritesNothing() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        let log = OperationLog(logURL: url, enabled: false)
        log.append(entry("/tmp/x"))
        log.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("CSV export quotes fields and includes rotated files")
    func exportsCSV() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(logURL: dir.appendingPathComponent("operations.log"), enabled: true, persistsEnabled: false, maxFileBytes: 400)
        log.append(entry("/tmp/with,comma"))
        for index in 0..<6 { log.append(entry("/tmp/file\(index)")) }

        let out = dir.appendingPathComponent("export.csv")
        try log.export(to: out, format: .csv)
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")

        #expect(lines.count == 8)   // header + 7 entries
        #expect(lines[0].hasPrefix("timestamp,action,outcome"))
        #expect(lines[1].contains("\"/tmp/with,comma\""))
    }

    @Test("Entries written before hash chaining still decode")
    func legacyEntriesDecode() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        let legacy = #"{"timestamp":"2026-08-01T10:00:00Z","action":"clean","path":"/tmp/old","sizeBytes":42,"mode":"trash","outcome":"success","dryRun":false}"# + "\n"
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let log = OperationLog(logURL: url)
        #expect(log.recent(limit: 5).first?.path == "/tmp/old")
        // No sidecar yet: totals are rebuilt from the file.
        #expect(log.totals().freedBytes == 42)
        #expect(log.totals().operations == 1)
        log.append(entry("/tmp/new", size: 8))
        #expect(log.totals().freedBytes == 50)
        #expect(log.totals().operations == 2)
        #expect(log.verifyChain().isIntact)
    }
}

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("Captures stdout and exit status")
    func capturesOutput() async {
        let output = await ProcessRunner.run("/bin/echo", ["hello"])
        #expect(output.succeeded)
        #expect(output.stdout == "hello\n")
    }

    @Test("Output larger than a pipe buffer doesn't deadlock")
    func largeOutput() async {
        // ~1 MB on stdout — far past the 64 KB pipe buffer.
        let output = await ProcessRunner.run("/bin/dd", ["if=/dev/zero", "bs=1024", "count=1024"], timeout: 20)
        #expect(output.exitCode == 0)
        #expect(output.stdout.utf8.count == 1_048_576)
    }

    @Test("A child that ignores SIGTERM is killed, within a bound")
    func killsStubbornChild() async {
        let start = Date()
        let output = await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"], timeout: 0.5)
        #expect(output.timedOut)
        #expect(Date().timeIntervalSince(start) < 0.5 + ProcessRunner.terminationGrace * 2 + 2)
    }

    @Test("A grandchild holding the pipe open doesn't hang the caller")
    func grandchildHoldingPipe() async {
        let start = Date()
        let output = await ProcessRunner.run("/bin/sh", ["-c", "/bin/sleep 20 & echo started"], timeout: 30)
        #expect(output.stdout == "started\n")
        #expect(output.exitCode == 0)
        #expect(Date().timeIntervalSince(start) < ProcessRunner.terminationGrace * 2 + 3)
    }

    @Test("A hung child is terminated at the timeout")
    func timesOut() async {
        let start = Date()
        let output = await ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(output.timedOut)
        #expect(!output.succeeded)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test("A missing executable reports a launch failure")
    func missingExecutable() async {
        let output = await ProcessRunner.run("/nonexistent/\(UUID().uuidString)")
        #expect(output.launchFailed)
        #expect(!output.succeeded)
    }
}

@Suite("ManagedPolicy")
struct ManagedPolicyTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "myKikau.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Values a user wrote locally are not policy")
    func unforcedValuesAreIgnored() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["clean"], forKey: ManagedPolicy.Key.disabledFeatures)
        defaults.set(false, forKey: ManagedPolicy.Key.forceOperationLog)
        defaults.set(["/tmp/x"], forKey: ManagedPolicy.Key.protectedPaths)

        let policy = ManagedPolicy(defaults: defaults)
        #expect(policy.isManaged == false)
        #expect(policy.disabledFeatures.isEmpty)
        #expect(policy.protectedPaths.isEmpty)
    }

    @Test("Policy keys are read and normalised")
    func readsKeys() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["Clean", "PURGE"], forKey: ManagedPolicy.Key.disabledFeatures)
        defaults.set(["/Users/Shared/Finance"], forKey: ManagedPolicy.Key.protectedPaths)
        defaults.set(["com.acme.security."], forKey: ManagedPolicy.Key.protectedBundlePrefixes)
        defaults.set(true, forKey: ManagedPolicy.Key.forceOperationLog)
        defaults.set(24, forKey: ManagedPolicy.Key.scheduledScanIntervalHours)

        let policy = ManagedPolicy(defaults: defaults, requireForced: false)
        #expect(policy.isManaged)
        #expect(policy.isFeatureDisabled("clean"))
        #expect(policy.isFeatureDisabled("purge"))
        #expect(!policy.isFeatureDisabled("analyze"))
        #expect(policy.protectedPaths == ["/Users/Shared/Finance"])
        #expect(policy.protectedBundlePrefixes == ["com.acme.security."])
        #expect(policy.forceOperationLog)
        #expect(policy.disableAutomaticUpdates == false)
        #expect(policy.scheduledScanIntervalHours == 24)
    }

    @Test("Exclusions combine the user's list with policy and are normalised")
    func exclusionStore() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ExclusionStore(defaults: defaults)
        store.setUserPaths(["/private/tmp/keep/", "/private/tmp/keep/", ""])

        #expect(store.userPaths == ["/private/tmp/keep/"])
        #expect(store.normalisedPaths == ["/tmp/keep"])

        let protection = PathProtection(
            home: URL(fileURLWithPath: "/Users/tester"),
            exclusions: { store.normalisedPaths },
            extraBundlePrefixes: { [] }
        )
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/tmp/keep/data.bin")))
    }
}
