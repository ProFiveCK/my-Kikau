import Testing
import Core
@testable import Features
import Foundation

@Suite("Privacy acknowledgment safety")
struct PrivacyAcknowledgmentSafetyTests {
    @Test("ignoring information cannot hide current conflicting permissions or enable automatic repair")
    func currentConflictsCannotBeIgnored() throws {
        let suite = "myKikau.privacy-safety.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NetworkPrivacyFindingStore(defaults: defaults)
        let path = "/Applications/Example.app/Contents/MacOS/Example"
        let denial = NetworkPrivacyAuditor.Rule(
            signingIdentifier: "com.example.app", executablePath: path,
            isDenied: true, preferenceWasSet: true
        )
        let installed = [NetworkPrivacyAuditor.InstalledApplication(bundleIdentifier: "com.example.app", executablePath: path)]
        let before = NetworkPrivacyAuditor.audit(rules: [denial], installedApplications: installed, fileExists: { _ in true })
        store.ignore(try #require(before.findings.first))

        let allowance = NetworkPrivacyAuditor.Rule(
            signingIdentifier: denial.signingIdentifier, executablePath: nil,
            isDenied: false, preferenceWasSet: true
        )
        let after = NetworkPrivacyAuditor.audit(rules: [denial, allowance], installedApplications: installed, fileExists: { _ in true })
        for finding in after.findings { store.ignore(finding) }
        let visible = store.applyingIgnores(to: after)
        #expect(visible.findings.map(\.kind) == [.conflictingPrivacyDecisions])
        #expect(visible.issueCount == 1)
        #expect(!visible.isHealthy)
        #expect(visible.autoFixableCount == 0)
        #expect(visible.requiresGuidedRepair)
        #expect(visible.ignoredFindings.map(\.kind) == [.installedApplicationDenied])
        #expect(visible.findings.first?.remediation == .guidedRecovery)
    }
}

/// Regression tests for the safety review (docs/CODEBASE_REVIEW_2026-10.md).
/// Each one pins a rule that was broken: a target that wasn't a cache, a
/// matcher that wasn't exact, a deletion that trusted its input.

private func makeTempDir() -> URL {
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

private func setModDate(_ url: URL, daysAgo: Double) {
    let date = Date().addingTimeInterval(-daysAgo * 86_400)
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

// MARK: - Clean targets

@Suite("Clean targets (safety)")
struct CleanTargetSafetyTests {
    private func allTargets(home: URL, running: Set<String> = []) -> [CleanScanner.Section: [URL]] {
        var result: [CleanScanner.Section: [URL]] = [:]
        for section in CleanScanner.Section.allCases {
            result[section] = CleanScanner.targets(for: section, home: home, runningBundleIDs: running)
        }
        return result
    }

    @Test("No section ever targets a browser profile, an active database or an archive")
    func neverTargetsUserData() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let forbidden = [
            "Library/Application Support/Firefox/Profiles",
            "Library/Application Support/Firefox",
            "Library/Application Support/Google/Chrome",
            "Library/Safari/CloudTabs.db",
            "Library/Safari",
            "Library/Developer/Xcode/Archives",
            ".m2/repository",
            "Library/Group Containers/UBF8T346G9.com.microsoft.teams",
        ]
        for relative in forbidden { makeDir(home.appendingPathComponent(relative)) }

        let targets = Set(allTargets(home: home).values.flatMap { $0 }.map(\.path))
        for relative in forbidden {
            let path = home.appendingPathComponent(relative).path
            #expect(!targets.contains(path), "\(relative) must never be a Clean target")
            // …nor may a target be a folder that contains it.
            #expect(!targets.contains { path.hasPrefix($0 + "/") }, "a Clean target contains \(relative)")
        }
    }

    @Test("A cache whose owning app is running is not a target, in any section")
    func skipsCachesOfRunningOwners() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        touch(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc/build.db"))
        touch(home.appendingPathComponent("Library/Caches/Google/Chrome/Cache/data"))
        touch(home.appendingPathComponent("Library/Application Support/Slack/Cache/data"))

        let idle = CleanScanner.currentTargetPaths(home: home, runningBundleIDs: [])
        let busy = CleanScanner.currentTargetPaths(
            home: home, runningBundleIDs: ["com.apple.dt.Xcode", "com.google.Chrome", "com.tinyspeck.slackmacgap"]
        )
        for relative in ["Library/Developer/Xcode/DerivedData", "Library/Caches/Google/Chrome", "Library/Application Support/Slack/Cache"] {
            let path = home.appendingPathComponent(relative).path
            #expect(idle.contains(path), "\(relative) should be a target when its app is closed")
            #expect(!busy.contains(path), "\(relative) must not be a target while its app runs")
        }
    }

    @Test("A plan is re-checked before review: what's now in use is dropped")
    func revalidationDropsInUseItems() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        touch(home.appendingPathComponent("Library/Caches/com.example.editor/data"))
        touch(home.appendingPathComponent("Library/Caches/com.example.idle/data"))
        let deleter = SafeFileDeleter()
        let plan = deleter.preview(
            CleanScanner.targets(for: .userAppCache, home: home, runningBundleIDs: []), category: .cache
        )
        #expect(plan.items.count == 2)

        // The editor was opened after the scan.
        let fresh = CleanScanner.revalidated(plan, home: home, runningBundleIDs: ["com.example.editor"])
        #expect(fresh.items.map(\.url.lastPathComponent) == ["com.example.idle"])
    }

    @Test("A temp folder with a recently written file inside is still in use")
    func tempFolderJudgedByContents() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("private/tmp/session")
        touch(folder.appendingPathComponent("live.sock"))
        // The folder itself looks old; the file inside was just written.
        setModDate(folder, daysAgo: 10)

        let names = CleanScanner.targets(for: .systemLogs, home: home).map(\.lastPathComponent)
        #expect(!names.contains("session"))
    }

    @Test("Shared containers are never targets themselves — only their children")
    func neverTargetsContainers() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        touch(home.appendingPathComponent("Library/Caches/com.example.app/data"))
        touch(home.appendingPathComponent("Library/Logs/SomeApp/app.log"))
        touch(home.appendingPathComponent("private/tmp/old.tmp"))
        touch(home.appendingPathComponent(".Trash/junk.txt"))

        let targets = Set(allTargets(home: home).values.flatMap { $0 }.map(\.path))
        for relative in ["Library/Caches", "Library/Logs", "private/tmp", ".Trash", "Library", ""] {
            let path = relative.isEmpty ? home.path : home.appendingPathComponent(relative).path
            #expect(!targets.contains(path), "\(relative.isEmpty ? "~" : relative) must not be a target")
        }
    }

    @Test("Logs section lists log folders individually and never myKikau's own operation log")
    func logsExcludeOwnAuditTrail() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        touch(home.appendingPathComponent("Library/Logs/SomeApp/app.log"))
        touch(home.appendingPathComponent("Library/Logs/myKikau/operations.log"))

        let names = CleanScanner.targets(for: .systemLogs, home: home).map(\.lastPathComponent)
        #expect(names.contains("SomeApp"))
        #expect(!names.contains("myKikau"))
    }

    @Test("Temporary files are only targets once they've gone untouched for three days")
    func tempFilesNeedToBeStale() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let fresh = home.appendingPathComponent("private/tmp/in-use.tmp")
        let stale = home.appendingPathComponent("private/tmp/forgotten.tmp")
        touch(fresh)
        touch(stale)
        setModDate(stale, daysAgo: 10)

        let names = CleanScanner.targets(for: .systemLogs, home: home).map(\.lastPathComponent)
        #expect(names.contains("forgotten.tmp"))
        #expect(!names.contains("in-use.tmp"))
    }

    @Test("Caches of running apps and com.apple.* caches are skipped")
    func skipsRunningAndAppleCaches() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches")
        touch(caches.appendingPathComponent("com.example.running/data"))
        touch(caches.appendingPathComponent("com.example.idle/data"))
        touch(caches.appendingPathComponent("com.apple.bird/data"))

        let names = CleanScanner.targets(
            for: .userAppCache, home: home, runningBundleIDs: ["com.example.running"]
        ).map(\.lastPathComponent)
        #expect(names == ["com.example.idle"])
    }

    @Test("Security-agent caches are planned as protected, never as removable")
    func securityAgentCachesAreProtected() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches")
        touch(caches.appendingPathComponent("com.crowdstrike.falcon.Agent/data"))
        touch(caches.appendingPathComponent("com.example.app/data"))

        let plan = CleanScanner.scan(.userAppCache, deleter: SafeFileDeleter(), home: home)
        #expect(plan.items.map(\.url.lastPathComponent) == ["com.example.app"])
        #expect(plan.protectedItems.map(\.url.lastPathComponent) == ["com.crowdstrike.falcon.Agent"])
    }

    @Test("Nothing is listed by two sections")
    func noDoubleCounting() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches")
        for name in ["Google/Chrome/Cache", "Firefox/Profiles", "com.spotify.client", "us.zoom.xos", "pip", "go-build", "com.example.app"] {
            touch(caches.appendingPathComponent(name).appendingPathComponent("data"))
        }

        let all = allTargets(home: home).values.flatMap { $0 }.map(\.path)
        // No path twice, and no target nested inside another section's target.
        #expect(Set(all).count == all.count)
        for path in all {
            #expect(!all.contains { $0 != path && path.hasPrefix($0 + "/") }, "\(path) is inside another target")
        }
    }
}

// MARK: - Deletion funnel

@Suite("SafeFileDeleter (safety)")
struct SafeFileDeleterSafetyTests {
    private func makeLog() -> (OperationLog, URL) {
        let dir = makeTempDir()
        return (OperationLog(logURL: dir.appendingPathComponent("operations.log")), dir)
    }

    @Test("execute re-checks protection and skips a protected item even if the plan lists it as removable")
    func executeRechecksProtection() {
        let (log, logDir) = makeLog()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let deleter = SafeFileDeleter(opLog: log)
        // A hand-built plan that claims a system path is fair game.
        let rogue = SafeFileDeleter.Item(
            url: URL(fileURLWithPath: "/System/Library/CoreServices"), sizeBytes: 1, category: .cache, protected: false
        )
        let plan = SafeFileDeleter.Plan(items: [rogue], protectedItems: [], missingItems: [])

        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "test")

        #expect(result.succeeded == 0)
        #expect(result.skipped == 1)
        #expect(result.removedIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: "/System/Library/CoreServices"))
        #expect(log.recent(limit: 5).first?.outcome == .skipped)
    }

    @Test("A .trash-category item outside a Trash folder is moved to the Trash, never removed outright")
    func permanentOnlyInsideTrash() {
        let (log, logDir) = makeLog()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("not-in-trash-\(UUID().uuidString).txt")
        try? Data("keep me recoverable".utf8).write(to: file)

        let deleter = SafeFileDeleter(opLog: log)
        let item = SafeFileDeleter.Item(url: file, sizeBytes: 19, category: .trash, protected: false)
        #expect(item.isPermanentRemoval == false)
        let result = deleter.execute(
            SafeFileDeleter.Plan(items: [item], protectedItems: [], missingItems: []),
            mode: .permanent, dryRun: false, action: "test"
        )

        #expect(result.succeeded == 1)
        #expect(result.recoverable == 1)
        let entry = log.recent(limit: 5).first
        #expect(entry?.mode == .trash)
        // It went to the Trash, and the log knows where — clean up via Put Back.
        let trashed = entry?.trashedPath
        #expect(trashed != nil)
        if let trashed { try? FileManager.default.removeItem(atPath: trashed) }
    }

    @Test("Items already inside a Trash folder are removed for good")
    func removesInsideTrash() {
        let (log, logDir) = makeLog()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".Trash/old.zip")
        touch(file, size: 32)

        let deleter = SafeFileDeleter(opLog: log)
        let plan = deleter.preview([file], category: .trash)
        #expect(plan.items.first?.isPermanentRemoval == true)
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "test")

        #expect(result.succeeded == 1)
        #expect(result.recoverable == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(log.recent(limit: 5).first?.mode == .permanent)
    }

    @Test("Put Back restores a trashed item and refuses to overwrite")
    func putBackRoundTrip() throws {
        let (log, logDir) = makeLog()
        defer { try? FileManager.default.removeItem(at: logDir) }
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("restore-\(UUID().uuidString).txt")
        try Data("contents".utf8).write(to: file)

        let deleter = SafeFileDeleter(opLog: log)
        _ = deleter.execute(deleter.preview([file], category: .cache), mode: .trash, dryRun: false, action: "test")
        let trashed = try #require(log.recent(limit: 5).first?.trashedPath)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try deleter.putBack(trashedPath: trashed, originalPath: file.path)
        #expect(String(data: try Data(contentsOf: file), encoding: .utf8) == "contents")

        // Nothing left in the Trash to put back a second time.
        #expect(throws: SafeFileDeleter.PutBackError.self) {
            try deleter.putBack(trashedPath: trashed, originalPath: file.path)
        }
    }

    @Test("A plan can be narrowed to the ticked items, and refreshed after a partial run")
    func planSubsets() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("a.bin")
        let b = tmp.appendingPathComponent("b.bin")
        touch(a, size: 10)
        touch(b, size: 20)
        let plan = SafeFileDeleter().preview([a, b, a], category: .cache)

        // Listing the same path twice doesn't double it.
        #expect(plan.items.count == 2)
        #expect(plan.keeping([a.path]).totalReclaimable == FileSizing.allocatedSize(of: a))
        #expect(plan.removing([a.path]).items.map(\.url) == [b])
    }

    @Test("directorySize counts hidden files")
    func sizeIncludesHidden() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        touch(tmp.appendingPathComponent("visible.bin"), size: 100)
        touch(tmp.appendingPathComponent(".hidden.bin"), size: 50)
        let total = SafeFileDeleter().directorySize(tmp)
        #expect(total >= 150)
        #expect(total == FileSizing.allocatedSize(of: tmp.appendingPathComponent("visible.bin"))
            + FileSizing.allocatedSize(of: tmp.appendingPathComponent(".hidden.bin")))
    }

    @Test("A cancelled run stops before touching the next item")
    func cancellationStops() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("survivor.bin")
        touch(file)
        let deleter = SafeFileDeleter()
        let result = deleter.execute(
            deleter.preview([file], category: .cache),
            mode: .trash, dryRun: false, action: "test", isCancelled: { true }
        )
        #expect(result.cancelled)
        #expect(result.succeeded == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

// MARK: - Leftovers

@Suite("LeftoverFinder (safety)")
struct LeftoverFinderSafetyTests {
    @Test("Uninstalling an app leaves a sibling app's data alone")
    func siblingAppDataSurvives() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let lib = home.appendingPathComponent("Library")
        let mine = "com.mykikau.test.browser"
        let sibling = "\(mine).canary"
        makeDir(lib.appendingPathComponent("Caches/\(mine)"))
        makeDir(lib.appendingPathComponent("Caches/\(sibling)"))
        touch(lib.appendingPathComponent("Preferences/\(mine).plist"))
        touch(lib.appendingPathComponent("Preferences/\(sibling).plist"))
        touch(lib.appendingPathComponent("Preferences/ByHost/\(mine).A1B2C3D4-0000-1111-2222-333344445555.plist"))
        touch(lib.appendingPathComponent("Preferences/ByHost/\(sibling).A1B2C3D4-0000-1111-2222-333344445555.plist"))
        touch(lib.appendingPathComponent("LaunchAgents/\(mine).plist"))
        touch(lib.appendingPathComponent("LaunchAgents/\(sibling).updater.plist"))
        makeDir(lib.appendingPathComponent("Group Containers/group.\(mine)"))
        makeDir(lib.appendingPathComponent("Group Containers/group.\(mine).shared-with-others"))

        let found = Set(LeftoverFinder.findLeftovers(bundleID: mine, home: home).map(\.lastPathComponent))

        #expect(found == [
            mine, "\(mine).plist", "\(mine).A1B2C3D4-0000-1111-2222-333344445555.plist", "group.\(mine)"
        ])
    }

    @Test("A malformed one-label bundle ID yields no leftovers at all")
    func malformedBundleIDFindsNothing() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        touch(home.appendingPathComponent("Library/Preferences/com.example.app.plist"))
        touch(home.appendingPathComponent("Library/Preferences/com.plist"))
        makeDir(home.appendingPathComponent("Library/Caches/com.example.app"))

        #expect(LeftoverFinder.findLeftovers(bundleID: "com", home: home).isEmpty)
        #expect(LeftoverFinder.findLeftovers(bundleID: "", home: home).isEmpty)
    }

    @Test("Helpers shipped inside the app are matched by their own exact IDs")
    func embeddedHelpersAreExactEvidence() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/Host.app")
        let helper = app.appendingPathComponent("Contents/Library/LoginItems/Helper.app")
        makeDir(helper.appendingPathComponent("Contents"))
        (["CFBundleIdentifier": "com.mykikau.test.host.helper"] as NSDictionary)
            .write(to: helper.appendingPathComponent("Contents/Info.plist"), atomically: true)

        let embedded = LeftoverFinder.embeddedBundleIDs(appURL: app)
        #expect(embedded == ["com.mykikau.test.host.helper"])

        let lib = home.appendingPathComponent("Library")
        makeDir(lib.appendingPathComponent("Caches/com.mykikau.test.host.helper"))
        makeDir(lib.appendingPathComponent("Caches/com.mykikau.test.host.unrelated"))
        let found = LeftoverFinder.findLeftovers(
            bundleID: "com.mykikau.test.host", home: home, embeddedBundleIDs: embedded
        ).map(\.lastPathComponent)
        #expect(found == ["com.mykikau.test.host.helper"])
    }

    @Test("Launch agents match by exact filename or a path inside the app, not by prefix")
    func agentMatchingIsExact() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(agents)
        let teardown = AppTeardown(home: home)
        let appPath = "/Applications/Thing.app"

        let exact = agents.appendingPathComponent("com.vendor.thing.plist")
        let sibling = agents.appendingPathComponent("com.vendor.thing.pro.plist")
        let lookalike = agents.appendingPathComponent("com.other.plist")
        (["Label": "x"] as NSDictionary).write(to: exact, atomically: true)
        (["Label": "x"] as NSDictionary).write(to: sibling, atomically: true)
        // Points at "/Applications/Thing.app.bak/…" — a different bundle.
        (["Label": "y", "Program": "/Applications/Thing.app.bak/Contents/MacOS/x"] as NSDictionary)
            .write(to: lookalike, atomically: true)

        #expect(teardown.matchesAgent(exact, bundleID: "com.vendor.thing", appPath: appPath) == true)
        #expect(teardown.matchesAgent(sibling, bundleID: "com.vendor.thing", appPath: appPath) == false)
        #expect(teardown.matchesAgent(lookalike, bundleID: "com.vendor.thing", appPath: appPath) == false)
    }
}

// MARK: - Duplicates

@Suite("DuplicateFinder")
struct DuplicateFinderTests {
    private func write(_ url: URL, _ data: Data) {
        makeDir(url.deletingLastPathComponent())
        try? data.write(to: url)
    }

    private func block(_ byte: UInt8, _ count: Int) -> Data {
        Data(repeating: byte, count: count)
    }

    @Test("Identical content is grouped; same-size files that differ are not")
    func findsTrueDuplicatesOnly() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let size = 2_000_000
        write(home.appendingPathComponent("Downloads/a.bin"), block(1, size))
        write(home.appendingPathComponent("Documents/copy-of-a.bin"), block(1, size))
        write(home.appendingPathComponent("Documents/different.bin"), block(2, size))

        let groups = DuplicateFinder.findDuplicates(home: home)

        #expect(groups.count == 1)
        #expect(Set(groups.first?.files.map(\.url.lastPathComponent) ?? []) == ["a.bin", "copy-of-a.bin"])
        #expect(groups.first?.reclaimableBytes == Int64(size))
    }

    @Test("Files that share their first and last 64 KB but differ in the middle are not duplicates")
    func middleDifferenceIsCaught() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let edge = block(7, 64 * 1024)
        write(home.appendingPathComponent("Downloads/one.bin"), edge + block(1, 1_000_000) + edge)
        write(home.appendingPathComponent("Downloads/two.bin"), edge + block(2, 1_000_000) + edge)

        #expect(DuplicateFinder.findDuplicates(home: home).isEmpty)
    }

    @Test("Hard links to one file are a single file, not duplicates")
    func hardLinksAreNotDuplicates() throws {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = home.appendingPathComponent("Downloads/original.bin")
        write(original, block(3, 1_500_000))
        try FileManager.default.linkItem(at: original, to: home.appendingPathComponent("Downloads/link.bin"))

        #expect(DuplicateFinder.walk(home: home).count == 1)
        #expect(DuplicateFinder.findDuplicates(home: home).isEmpty)
    }

    @Test("A file that can't be read produces no hash rather than a partial one")
    func unreadableFileHasNoHash() {
        #expect(DuplicateFinder.contentHash(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")) == nil)
        #expect(DuplicateFinder.partialHash(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), size: 10) == nil)
    }

    @Test("The keeper can be changed, and the plan removes everything except it")
    func keeperSelection() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let older = home.appendingPathComponent("Downloads/older.bin")
        let newer = home.appendingPathComponent("Downloads/newer.bin")
        write(older, block(5, 1_200_000))
        write(newer, block(5, 1_200_000))
        setModDate(older, daysAgo: 30)

        let group = DuplicateFinder.findDuplicates(home: home)[0]
        #expect(group.keeper?.url.lastPathComponent == "newer.bin")

        let olderID = group.files.first { $0.url.lastPathComponent == "older.bin" }?.id ?? ""
        let newerID = group.files.first { $0.url.lastPathComponent == "newer.bin" }?.id ?? ""
        let swapped = group.keeping(olderID)
        #expect(swapped.keeper?.url.lastPathComponent == "older.bin")
        let plan = DuplicateFinder.duplicatePlan(for: [swapped], deleter: SafeFileDeleter())
        #expect(plan.items.map(\.url.lastPathComponent) == ["newer.bin"])
        #expect(swapped.removing([newerID]) == nil)
    }

    @Test("Large files honour an explicit threshold")
    func largeFileThreshold() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        write(home.appendingPathComponent("Movies/big.mov"), block(1, 3_000_000))
        write(home.appendingPathComponent("Movies/small.mov"), block(1, 500_000))

        let large = DuplicateFinder.findLargeFiles(home: home, threshold: 1_000_000)
        #expect(large.map(\.url.lastPathComponent) == ["big.mov"])
    }
}

// MARK: - Scanning

@Suite("Scanning")
struct ScanningTests {
    @Test("A folder measured as part of its parent is remembered, so drilling in doesn't walk it again")
    func sizeCacheRecordsLargeFolders() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("parent/big")
        let small = root.appendingPathComponent("parent/small")
        touch(big.appendingPathComponent("data.bin"), size: 9_000_000)
        touch(small.appendingPathComponent("data.bin"), size: 1000)

        let cache = DiskScanner.SizeCache()
        let entries = DiskScanner.scan(root, cache: cache)

        #expect(entries.count == 1)
        let recorded = cache.size(for: big.path)
        #expect(recorded != nil)
        #expect((recorded ?? 0) >= 9_000_000)
        // Small folders aren't worth remembering.
        #expect(cache.size(for: small.path) == nil)

        // Invalidating a folder forgets it and the ancestors whose totals included it.
        cache.invalidate(big.path)
        #expect(cache.size(for: big.path) == nil)
        #expect(cache.size(for: root.appendingPathComponent("parent").path) == nil)
    }

    @Test("An unreadable folder elsewhere doesn't stop caching complete folders, but its ancestors aren't cached")
    func sizeCacheSurvivesPartialCoverage() throws {
        let root = makeTempDir()
        let denied = root.appendingPathComponent("parent/denied")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
            try? FileManager.default.removeItem(at: root)
        }
        let big = root.appendingPathComponent("parent/big")
        touch(big.appendingPathComponent("data.bin"), size: 9_000_000)
        touch(denied.appendingPathComponent("data.bin"), size: 9_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)

        // Another walk sharing this recorder has already hit a denied read.
        let coverage = ScanCoverageRecorder()
        coverage.record(URL(fileURLWithPath: "/elsewhere"), kind: .denied, detail: "denied")
        let cache = DiskScanner.SizeCache()
        _ = DiskScanner.scan(root, cache: cache, coverage: coverage)

        #expect((cache.size(for: big.path) ?? 0) >= 9_000_000)
        // `parent` holds an unreadable folder, so its total is a lower bound.
        #expect(cache.size(for: root.appendingPathComponent("parent").path) == nil)
    }

    @Test("A cancelled walk returns nothing and records nothing")
    func cancelledWalkStops() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        touch(root.appendingPathComponent("folder/data.bin"), size: 9_000_000)

        let cache = DiskScanner.SizeCache()
        let token = DiskScanner.Token()
        token.cancel()

        #expect(DiskScanner.scan(root, token: token, cache: cache).isEmpty)
        #expect(cache.size(for: root.appendingPathComponent("folder").path) == nil)
    }

    @Test("Symbolic links are not followed when measuring")
    func symlinksNotFollowed() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        touch(outside.appendingPathComponent("huge.bin"), size: 5_000_000)
        touch(root.appendingPathComponent("real.bin"), size: 4096)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: outside
        )

        #expect(DiskScanner.directorySize(root) < 1_000_000)
    }

    @Test("largeFiles keeps only the biggest N, largest first")
    func largeFilesTopN() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...12 {
            touch(root.appendingPathComponent("sub\(index % 3)/file\(index).bin"), size: index * 100_000)
        }

        let top = DiskScanner.largeFiles(in: root, limit: 3)
        #expect(top.map(\.name) == ["file12.bin", "file11.bin", "file10.bin"])
    }

    @Test("The concurrent Clean scan finds what the serial one does")
    func concurrentCleanScanMatchesSerial() async {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        touch(home.appendingPathComponent("Library/Caches/com.example.app/cache.bin"), size: 64)
        touch(home.appendingPathComponent("Library/Logs/SomeApp/app.log"), size: 32)
        touch(home.appendingPathComponent(".Trash/junk.txt"), size: 16)

        let deleter = SafeFileDeleter()
        let serial = CleanScanner.scanAll(deleter: deleter, home: home)
        let concurrent = await CleanScanner.scanAllConcurrently(deleter: deleter, home: home)

        #expect(concurrent.count == CleanScanner.Section.allCases.count)
        for section in CleanScanner.Section.allCases {
            #expect(Set(concurrent[section]?.items.map(\.id) ?? []) == Set(serial[section]?.items.map(\.id) ?? []))
        }
    }

    @Test("The diagnostics report carries no paths from the user's home folder")
    func diagnosticsHasNoPaths() {
        let report = DiagnosticsReport.generate(appVersion: "0.0.0", build: "0")
        #expect(report.contains("myKikau diagnostics"))
        #expect(!report.contains(NSHomeDirectory()))
        #expect(!report.contains("/Users/"))
    }
}

// MARK: - Findings from the independent review

@Suite("Review follow-ups")
struct ReviewFollowUpTests {
    private func write(_ url: URL, _ data: Data) {
        makeDir(url.deletingLastPathComponent())
        try? data.write(to: url)
    }

    @Test("Duplicates: if the kept copy has gone, nothing from that set is planned")
    func staleKeeperPlansNothing() throws {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let data = Data(repeating: 9, count: 1_500_000)
        write(home.appendingPathComponent("Downloads/a.bin"), data)
        write(home.appendingPathComponent("Documents/b.bin"), data)
        let group = try #require(DuplicateFinder.findDuplicates(home: home).first)
        let keeper = try #require(group.keeper)

        // The user deletes the kept copy in Finder after the scan.
        try FileManager.default.removeItem(at: keeper.url)

        #expect(DuplicateFinder.stillValid(group) == nil)
        #expect(DuplicateFinder.duplicatePlan(for: [group], deleter: SafeFileDeleter()).items.isEmpty)
    }

    @Test("Duplicates: a copy edited since the scan is no longer removed")
    func editedCopyIsNotPlanned() throws {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let data = Data(repeating: 9, count: 1_500_000)
        for name in ["a.bin", "b.bin", "c.bin"] { write(home.appendingPathComponent("Downloads/\(name)"), data) }
        let group = try #require(DuplicateFinder.findDuplicates(home: home).first)
        let edited = group.files[1]

        try Data(repeating: 1, count: 1_500_000).write(to: edited.url)
        setModDate(edited.url, daysAgo: -1)

        let plan = DuplicateFinder.duplicatePlan(for: [group], deleter: SafeFileDeleter())
        #expect(plan.items.count == 1)
        #expect(!plan.items.contains { $0.url.lastPathComponent == edited.url.lastPathComponent })
    }

    @Test("Uninstalling one of two copies of an app plans no leftovers and stops no services")
    func sharedCopyKeepsItsData() async {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundleID = "com.mykikau.test.twocopies"
        func makeApp(_ relative: String) -> URL {
            let app = home.appendingPathComponent(relative)
            makeDir(app.appendingPathComponent("Contents"))
            (["CFBundleIdentifier": bundleID] as NSDictionary)
                .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
            return app
        }
        let first = makeApp("Applications/Twin.app")
        let second = makeApp("Other/Twin.app")
        let info = AppInventory.AppInfo(url: first, name: "Twin", bundleID: bundleID, version: nil, sizeBytes: 0, lastModified: nil)

        #expect(AppInventory.otherCopies(of: info, among: [first, second]) == [second])
        #expect(AppInventory.otherCopies(of: info, among: [first]).isEmpty)

        // Teardown leaves agents and login items alone when another copy exists.
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(agents)
        (["Label": bundleID] as NSDictionary).write(to: agents.appendingPathComponent("\(bundleID).plist"), atomically: true)
        let loginItems = StubLoginItemService()
        let teardown = AppTeardown(
            home: home, opLog: OperationLog(logURL: home.appendingPathComponent("log/operations.log")),
            loginItemService: loginItems, otherCopies: { _ in [second] }
        )
        let result = await teardown.teardown(app: info, dryRun: true)
        #expect(result.skippedBecauseOtherCopyInstalled)
        #expect(result.launchAgentsUnloaded.isEmpty)
        #expect(result.loginItemsRemoved.isEmpty)
        #expect(loginItems.removeByNameCalls.isEmpty)
    }

    @Test("Team-ID and group forms only count inside Group Containers")
    func groupFormsOnlyInGroupContainers() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let lib = home.appendingPathComponent("Library")
        let bundleID = "com.mykikau.test.groupforms"
        makeDir(lib.appendingPathComponent("Group Containers/ABCDE12345.\(bundleID)"))
        // The same shape of name elsewhere is some other identifier.
        makeDir(lib.appendingPathComponent("Application Support/ABCDE12345.\(bundleID)"))
        makeDir(lib.appendingPathComponent("Caches/group.\(bundleID)"))
        // A ten-letter word is not a Team ID, even in Group Containers.
        makeDir(lib.appendingPathComponent("Group Containers/university.\(bundleID)"))

        let found = LeftoverFinder.findLeftovers(bundleID: bundleID, home: home)
        #expect(found.map(\.lastPathComponent) == ["ABCDE12345.\(bundleID)"])
        #expect(found.first?.deletingLastPathComponent().lastPathComponent == "Group Containers")
    }

    @Test("CPU usage survives the kernel's 32-bit tick counters wrapping")
    func cpuCountersWrap() {
        let near = UInt32.max - 50
        // Each counter advances by 100 ticks and wraps past zero.
        let usage = MetricsCollector.cpuUsage(
            previous: (near, near, near, near),
            current: (near &+ 100, near &+ 100, near &+ 200, near &+ 0)
        )
        // user 100 + system 100 busy, idle 200, nice 0 → 50 %.
        #expect(abs(usage - 50) < 0.001)
        #expect(MetricsCollector.cpuUsage(previous: (1, 1, 1, 1), current: (1, 1, 1, 1)) == 0)
    }

    @Test("Put Back refuses a different item that later landed at the same Trash path")
    func putBackChecksIdentity() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(logURL: dir.appendingPathComponent("log/operations.log"))
        let deleter = SafeFileDeleter(opLog: log)
        let original = dir.appendingPathComponent("report-\(UUID().uuidString).txt")
        try Data("first".utf8).write(to: original)

        _ = deleter.execute(deleter.preview([original], category: .cache), mode: .trash, dryRun: false, action: "test")
        let entry = try #require(log.recent(limit: 5).first)
        let trashed = try #require(entry.trashedPath)
        let number = try #require(entry.trashedFileNumber)
        defer { try? FileManager.default.removeItem(atPath: trashed) }

        // The Trash is emptied, and something else ends up under that name.
        try FileManager.default.removeItem(atPath: trashed)
        try Data("an unrelated file".utf8).write(to: URL(fileURLWithPath: trashed))

        #expect(deleter.canPutBack(trashedPath: trashed, originalPath: original.path, fileNumber: number) == false)
        #expect(throws: SafeFileDeleter.PutBackError.self) {
            try deleter.putBack(trashedPath: trashed, originalPath: original.path, fileNumber: number)
        }
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test("Purge finds dot-named build folders")
    func purgeFindsHiddenTargets() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        touch(home.appendingPathComponent("Projects/app/.build/debug/app.o"), size: 100)
        touch(home.appendingPathComponent("Projects/site/.next/cache/data"), size: 100)
        touch(home.appendingPathComponent("Projects/site/src/index.js"), size: 10)

        let found = Set(ProjectArtifactScanner.scan(deleter: SafeFileDeleter(), home: home).map(\.artifactType))
        #expect(found == [".build", ".next"])
    }
}

// MARK: - Leftovers from removed apps, startup items

@Suite("OrphanFinder")
struct OrphanFinderTests {
    private func seed(_ home: URL, _ relative: String, daysOld: Double) {
        let url = home.appendingPathComponent("Library").appendingPathComponent(relative)
        if url.pathExtension.isEmpty {
            touch(url.appendingPathComponent("data.bin"))
            setModDate(url.appendingPathComponent("data.bin"), daysAgo: daysOld)
        } else {
            touch(url)
        }
        setModDate(url, daysAgo: daysOld)
    }

    @Test("Only old, fully-qualified, unowned identifiers are suggested")
    func findsOnlyTrueOrphans() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        seed(home, "Application Support/com.gone.oldapp", daysOld: 200)
        seed(home, "Preferences/com.gone.oldapp.plist", daysOld: 200)
        // Still installed.
        seed(home, "Caches/com.vendor.present", daysOld: 200)
        // A helper of an installed app.
        seed(home, "Caches/com.vendor.present.helper", daysOld: 200)
        // Used recently.
        seed(home, "Caches/com.gone.recent", daysOld: 5)
        // Apple's, a security agent's, and names that aren't identifiers.
        seed(home, "Caches/com.apple.something", daysOld: 200)
        seed(home, "Caches/com.crowdstrike.falcon.Agent", daysOld: 200)
        seed(home, "Application Support/Google", daysOld: 200)
        seed(home, "Application Support/My App", daysOld: 200)
        seed(home, "Caches/pip", daysOld: 200)
        seed(home, "Caches/vendor.app", daysOld: 200)
        // Registered with Launch Services though not in /Applications.
        seed(home, "Caches/com.elsewhere.tool", daysOld: 200)
        // Containers are never searched.
        seed(home, "Containers/com.gone.sandboxed", daysOld: 200)

        let found = OrphanFinder.find(
            home: home,
            installedBundleIDs: ["com.vendor.present"],
            isRegistered: { $0 == "com.elsewhere.tool" }
        )

        #expect(found.map(\.url.lastPathComponent).sorted() == ["com.gone.oldapp", "com.gone.oldapp.plist"])
        #expect(Set(found.map(\.bundleID)) == ["com.gone.oldapp"])
    }

    @Test("A folder with something recent inside is not an orphan")
    func recentContentsKeepAFolder() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("Library/Application Support/com.gone.active")
        touch(folder.appendingPathComponent("state.db"))
        setModDate(folder, daysAgo: 300)

        #expect(OrphanFinder.find(home: home, installedBundleIDs: [], isRegistered: { _ in false }).isEmpty)
    }

    @Test("Entry names that aren't bundle identifiers are ignored")
    func parsesBundleIDs() {
        #expect(OrphanFinder.bundleID(fromEntryName: "com.example.app") == "com.example.app")
        #expect(OrphanFinder.bundleID(fromEntryName: "com.example.app.plist") == "com.example.app")
        #expect(OrphanFinder.bundleID(fromEntryName: "com.example.app.savedState") == "com.example.app")
        #expect(OrphanFinder.bundleID(fromEntryName: "example.app") == nil)
        #expect(OrphanFinder.bundleID(fromEntryName: "Google") == nil)
        #expect(OrphanFinder.bundleID(fromEntryName: "1.2.3") == nil)
        #expect(OrphanFinder.bundleID(fromEntryName: "My App.v2.data") == nil)
    }
}

@Suite("StartupItems")
struct StartupItemsTests {
    @Test("User agents are removable; Apple's and security agents' are not")
    func classifiesItems() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(agents)
        (["Label": "com.vendor.updater", "Program": "/nonexistent/vendor/updater", "RunAtLoad": true] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.vendor.updater.plist"), atomically: true)
        (["Label": "com.vendor.inapp", "ProgramArguments": ["/Applications/Vendor.app/Contents/MacOS/helper"]] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.vendor.inapp.plist"), atomically: true)
        (["Label": "com.apple.thing", "Program": "/nonexistent"] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.apple.thing.plist"), atomically: true)
        (["Label": "com.jamf.agent", "Program": "/nonexistent"] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.jamf.agent.plist"), atomically: true)

        let items = StartupItems.scan(home: home).filter { $0.scope == .user }
        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })

        #expect(byLabel["com.vendor.updater"]?.isRemovable == true)
        #expect(byLabel["com.vendor.updater"]?.programMissing == true)
        #expect(byLabel["com.vendor.updater"]?.runsAtLoad == true)
        #expect(byLabel["com.vendor.inapp"]?.owningAppName == "Vendor")
        #expect(byLabel["com.apple.thing"]?.isRemovable == false)
        #expect(byLabel["com.jamf.agent"]?.isRemovable == false)

        // The plan drops anything that isn't removable, whatever is passed in.
        let plan = StartupItems.removalPlan(for: items, deleter: SafeFileDeleter())
        #expect(Set(plan.items.map(\.url.lastPathComponent)) == ["com.vendor.updater.plist", "com.vendor.inapp.plist"])
    }

    @Test("System-wide items need the administrator helper, and bring only the exact helper tool they run")
    func systemItemsThroughHelper() throws {
        let home = makeTempDir()
        let library = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: library)
        }
        let daemons = library.appendingPathComponent("LaunchDaemons")
        let agents = library.appendingPathComponent("LaunchAgents")
        let tools = library.appendingPathComponent("PrivilegedHelperTools")
        makeDir(daemons)
        makeDir(agents)
        let tool = tools.appendingPathComponent("com.vendor.daemon")
        touch(tool)
        touch(tools.appendingPathComponent("nested/com.vendor.deep"))
        try FileManager.default.createSymbolicLink(at: tools.appendingPathComponent("com.vendor.linked"), withDestinationURL: tool)
        // A user agent that happens to name a helper tool never brings it along.
        let userAgents = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(userAgents)
        (["Label": "com.vendor.user", "Program": tool.path] as NSDictionary)
            .write(to: userAgents.appendingPathComponent("com.vendor.user.plist"), atomically: true)
        for (dir, label, program) in [
            (daemons, "com.vendor.daemon", tool.path),
            (daemons, "com.vendor.deep", tools.appendingPathComponent("nested/com.vendor.deep").path),
            (daemons, "com.vendor.linked", tools.appendingPathComponent("com.vendor.linked").path),
            (daemons, "com.apple.thing", tools.appendingPathComponent("com.apple.thing").path),
            (daemons, "com.jamf.agent", tools.appendingPathComponent("com.jamf.agent").path),
            (agents, "com.vendor.updater", library.appendingPathComponent("Application Support/Vendor/Updater").path),
        ] {
            (["Label": label, "ProgramArguments": [program]] as NSDictionary)
                .write(to: dir.appendingPathComponent("\(label).plist"), atomically: true)
        }

        let items = StartupItems.scan(home: home, library: library)
        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })
        let daemon = try #require(byLabel["com.vendor.daemon"])

        #expect(daemon.helperTool?.path == tool.path)
        #expect(byLabel["com.vendor.deep"]?.helperTool == nil)
        #expect(byLabel["com.vendor.linked"]?.helperTool == nil)
        #expect(byLabel["com.vendor.updater"]?.helperTool == nil)
        #expect(byLabel["com.vendor.user"]?.helperTool == nil)

        // Without the helper, system-wide items can't be ticked; with it they can.
        #expect(daemon.needsAdministrator && !daemon.isRemovable)
        #expect(!daemon.canRemove(helperEnabled: false))
        #expect(daemon.canRemove(helperEnabled: true))
        // Apple's and device-management items never, helper or not.
        #expect(byLabel["com.apple.thing"]?.canRemove(helperEnabled: true) == false)
        #expect(byLabel["com.jamf.agent"]?.canRemove(helperEnabled: true) == false)

        let deleter = SafeFileDeleter()
        let withoutHelper = StartupItems.removalPlan(for: items, deleter: deleter)
        #expect(Set(withoutHelper.items.map(\.url.lastPathComponent)) == ["com.vendor.user.plist"])

        // Folder and name: the temporary folder may come back as /private/var.
        let withHelper = StartupItems.removalPlan(for: items, helperEnabled: true, deleter: deleter)
        #expect(Set(withHelper.items.map { "\($0.url.deletingLastPathComponent().lastPathComponent)/\($0.url.lastPathComponent)" }) == [
            "LaunchAgents/com.vendor.user.plist",
            "LaunchDaemons/com.vendor.daemon.plist",
            "PrivilegedHelperTools/com.vendor.daemon",
            "LaunchDaemons/com.vendor.deep.plist",
            "LaunchDaemons/com.vendor.linked.plist",
            "LaunchAgents/com.vendor.updater.plist",
        ])
    }
}

@Suite("Care foundation safety")
struct CareFoundationSafetyTests {
    @Test("A maintenance apply refuses files that were not in the reviewed scan")
    func maintenanceRequiresReviewedPaths() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let states = home.appendingPathComponent("Library/Saved Application State")
        let old = states.appendingPathComponent("com.fixture.old.savedState")
        let added = states.appendingPathComponent("com.fixture.new.savedState")
        for url in [old, added] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("state".utf8).write(to: url.appendingPathComponent("state.txt"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: url.path)
        }
        let log = OperationLog(logURL: home.appendingPathComponent("audit/operations.log"))
        let result = await MaintenanceRunner(home: home, opLog: log).run(taskID: "saved_state", dryRun: false, reviewedPaths: [old.path])
        if case .failed = result.outcome {} else { Issue.record("Unreviewed paths must stop the operation") }
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: added.path))
    }

    @Test("An unreadable maintenance directory is unavailable, not healthy")
    func unreadableMaintenance() async throws {
        guard getuid() != 0 else { return }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let states = home.appendingPathComponent("Library/Saved Application State")
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: states.path)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: states.path)
        let result = await MaintenanceRunner(home: home, opLog: OperationLog(logURL: home.appendingPathComponent("audit/operations.log"))).run(taskID: "saved_state", dryRun: true)
        if case .unavailable = result.outcome {} else { Issue.record("Denied reads cannot be an all-clear: \(result.outcome)") }
    }

    @Test("Missing comparison inputs produce evidence rather than false duplicate matches")
    func hashReadFailure() {
        let c = ScanCoverageRecorder()
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/missing")
        #expect(DuplicateFinder.contentHash(url, coverage: c) == nil)
        #expect(c.snapshot.issues.count == 1)
        #expect(c.snapshot.issues.first?.kind == .missing)
    }
}

@Suite("Simulation accounting safety")
struct SimulationAccountingSafetyTests {
    @Test("Simulation reports a Trash move even when permanent removal is requested outside Trash")
    func predictsEffectiveMode() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(logURL: dir.appendingPathComponent("audit/operations.log"))
        let deleter = SafeFileDeleter(opLog: log)
        let plan = SafeFileDeleter.Plan(items: [
            .init(url: dir.appendingPathComponent("fixture"), sizeBytes: 100, category: .cache, protected: false)
        ], protectedItems: [], missingItems: [])
        let result = deleter.execute(plan, mode: .permanent, dryRun: true, action: "fixture")
        #expect(result.dryRun)
        #expect(result.recoverable == 1)
        #expect(result.removedIDs.isEmpty)
        #expect(log.totals().freedBytes == 0)
        #expect(log.totals().trashedBytes == 0)
    }
}


@Suite("Session recovery safety")
struct SessionRecoverySafetyTests {
    @Test("Restore rechecks exclusions and does not move into a newly protected destination")
    func excludedDestination() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(".Trash/item")
        touch(source)
        let destination = root.appendingPathComponent("excluded/item")
        let protection = PathProtection(home: root, exclusions: { [destination.deletingLastPathComponent().path] })
        let deleter = SafeFileDeleter(protection: protection)
        #expect(!deleter.canPutBack(trashedPath: source.path, originalPath: destination.path))
        #expect(throws: SafeFileDeleter.PutBackError.protectedLocation) {
            try deleter.putBack(trashedPath: source.path, originalPath: destination.path)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("A forged Trash parent symlink cannot restore a file outside the Trash")
    func trashParentSymlink() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        touch(outside.appendingPathComponent("item"))
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: outside)
        let deleter = SafeFileDeleter()
        #expect(!deleter.canPutBack(trashedPath: trash.appendingPathComponent("item").path, originalPath: root.appendingPathComponent("restored").path))
        #expect(throws: SafeFileDeleter.PutBackError.noLongerInTrash) {
            try deleter.putBack(trashedPath: trash.appendingPathComponent("item").path, originalPath: root.appendingPathComponent("restored").path)
        }
    }

    @Test("Batch recovery requires a recorded identity, not just a matching Trash name")
    func missingIdentity() {
        let entry = OperationLog.Entry(action: "clean", path: "/tmp/restored", sizeBytes: 1, mode: .trash,
                                       outcome: .success, dryRun: false, trashedPath: "/tmp/.Trash/item")
        let session = CleanupSession(id: UUID(), entries: [entry])
        #expect(CleanupRecovery.preview(session).first?.isAvailable == false)
    }
}

@Suite("Menu bar Trash review safety")
struct MenuBarTrashReviewSafetyTests {
    @Test("Preparing a menu bar Trash review lists exact Trash children and changes nothing")
    func reviewIsReadOnlyAndScoped() throws {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let trashFile = home.appendingPathComponent(".Trash/old-download.txt")
        let document = home.appendingPathComponent("Documents/keep.txt")
        touch(trashFile)
        touch(document)
        let log = OperationLog(logURL: home.appendingPathComponent("operations.log"))
        let review = TrashReview.prepare(home: home, deleter: SafeFileDeleter(opLog: log))
        #expect(review.plan.items.map { $0.url.resolvingSymlinksInPath().path } == [trashFile.resolvingSymlinksInPath().path])
        #expect(review.plan.items.allSatisfy { $0.category == .trash && $0.isPermanentRemoval })
        #expect(FileManager.default.fileExists(atPath: trashFile.path))
        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(log.recent().isEmpty)
    }
}

@Suite("Cleanup review safety")
struct CleanupReviewSafetyTests {
    @Test("A symlink posing as a Trash parent cannot authorise permanent removal")
    func permanentRemovalResolvesParent() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        let file = outside.appendingPathComponent("keep.txt")
        touch(file)
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: outside)
        let alias = trash.appendingPathComponent("keep.txt")
        let item = SafeFileDeleter.Item(url: alias, sizeBytes: 8, category: .trash, protected: false)
        #expect(!item.isPermanentRemoval)
        let log = OperationLog(logURL: root.appendingPathComponent("audit/operations.log"))
        let result = SafeFileDeleter(opLog: log).execute(
            .init(items: [item], protectedItems: [], missingItems: []),
            mode: .permanent, dryRun: true, action: "fixture"
        )
        #expect(result.recoverable == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(log.recent().first?.mode == .trash)
    }

    @Test("Deleting a symlink in a physical Trash leaves its destination intact")
    func trashLeafSymlink() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("keep.txt")
        touch(outside)
        let link = root.appendingPathComponent(".Trash/link")
        makeDir(link.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(SafeFileDeleter.isInsideTrash(link))
        let deleter = SafeFileDeleter(opLog: OperationLog(logURL: root.appendingPathComponent("audit/operations.log")))
        let result = deleter.execute(deleter.preview([link], category: .trash), mode: .trash, dryRun: false, action: "fixture")
        #expect(result.succeeded == 1)
        #expect(result.recoverable == 0)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test("Trash failure guidance tells the user to empty it in Finder")
    func trashFailureGuidance() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let trash = SafeFileDeleter.Failure(path: home.appendingPathComponent(".Trash/App.app").path,
                                          reason: "Denied", needsAdministrator: true)
        #expect(trash.recoverySuggestion.contains("Empty Trash"))
        let application = SafeFileDeleter.Failure(path: "/Applications/App.app", reason: "Denied", needsAdministrator: true)
        #expect(application.recoverySuggestion.contains("Move this item"))
    }

    @Test("Execution rechecks security-agent descendants added after preview")
    func newProtectedDescendant() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        touch(cache.appendingPathComponent("ordinary"))
        let deleter = SafeFileDeleter(opLog: OperationLog(logURL: root.appendingPathComponent("audit/operations.log")))
        let plan = deleter.preview([cache], category: .cache)
        #expect(plan.items.count == 1)
        let protected = cache.appendingPathComponent("com.jamf.agent/state")
        touch(protected)
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "fixture")
        #expect(result.skipped == 1)
        #expect(result.succeeded == 0)
        #expect(FileManager.default.fileExists(atPath: protected.path))
    }

    @Test("Command-line build activity excludes developer caches, including after the scan")
    func commandLineBuilds() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/go-build")
        touch(cache.appendingPathComponent("data"))
        let idle = CleanScanner.targets(for: .devTools, home: home, runningToolNames: [])
        #expect(idle.contains { $0.resolvingSymlinksInPath().path == cache.resolvingSymlinksInPath().path })
        let plan = SafeFileDeleter().preview([cache], category: .cache)
        for tool in ["go", "node", "java", "swift-frontend", "xcodebuild", "cargo"] {
            #expect(CleanScanner.targets(for: .devTools, home: home, runningToolNames: [tool]).isEmpty)
            #expect(CleanScanner.revalidated(plan, home: home, runningToolNames: [tool]).items.isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Developer caches cannot bypass build protection through User App Cache")
    func buildCacheSectionOwnership() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let names = ["node-gyp", "org.swift.swiftpm", "org.llvm.clang", "Homebrew"]
        for name in names { touch(home.appendingPathComponent("Library/Caches/\(name)/cache")) }
        let ordinary = CleanScanner.targets(for: .userAppCache, home: home, runningToolNames: ["node"])
        #expect(ordinary.isEmpty)
        let developer = CleanScanner.scan(.devTools, home: home)
        #expect(Set(developer.items.map(\.url.lastPathComponent)) == Set(names))
        #expect(CleanScanner.revalidated(developer, home: home, runningToolNames: ["node"]).items.isEmpty)
    }

    @Test("An old temporary folder with fresh deeply nested files is not stale")
    func activeNestedTemporaryFiles() {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let entry = home.appendingPathComponent("private/tmp/build-job")
        let nested = entry.appendingPathComponent("a/b/c")
        let fresh = nested.appendingPathComponent("active.db")
        touch(fresh)
        for path in [entry, entry.appendingPathComponent("a"), entry.appendingPathComponent("a/b"), nested] {
            setModDate(path, daysAgo: 10)
        }
        #expect(!CleanScanner.targets(for: .systemLogs, home: home).contains {
            $0.resolvingSymlinksInPath().path == entry.resolvingSymlinksInPath().path
        })
        setModDate(fresh, daysAgo: 10)
        #expect(CleanScanner.targets(for: .systemLogs, home: home).contains {
            $0.resolvingSymlinksInPath().path == entry.resolvingSymlinksInPath().path
        })
    }

    @Test("Every maintenance file-removal task requires an explicit path review")
    func missingMaintenanceReview() async {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let oldState = home.appendingPathComponent("Library/Saved Application State/com.fixture.old.savedState")
        touch(oldState.appendingPathComponent("state"))
        setModDate(oldState, daysAgo: 60)
        let config = home.appendingPathComponent("Library/Preferences/com.fixture.broken.plist")
        touch(config)
        setModDate(config, daysAgo: 10)
        let list = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/broken.sfl3")
        touch(list)
        let agent = home.appendingPathComponent("Library/LaunchAgents/com.fixture.missing.plist")
        makeDir(agent.deletingLastPathComponent())
        (["Label": "com.fixture.missing", "Program": "/nonexistent/fixture/tool"] as NSDictionary).write(to: agent, atomically: true)
        let runner = MaintenanceRunner(home: home, opLog: OperationLog(logURL: home.appendingPathComponent("audit/operations.log")))
        for id in ["saved_state", "broken_configs", "shared_file_lists", "launch_agents"] {
            let result = await runner.run(taskID: id, dryRun: false)
            if case .failed = result.outcome {} else { Issue.record("Missing review must stop \(id): \(result.outcome)") }
        }
        for url in [oldState, config, list, agent] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test("Cancelled maintenance never removes files, spawns commands or starts the next task")
    func cancelledMaintenance() async {
        let home = makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let state = home.appendingPathComponent("Library/Saved Application State/com.fixture.old.savedState")
        touch(state.appendingPathComponent("state"))
        setModDate(state, daysAgo: 60)
        let marker = home.appendingPathComponent("must-not-exist")
        let runner = MaintenanceRunner(home: home, opLog: OperationLog(logURL: home.appendingPathComponent("audit/operations.log")))
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let result = await runner.run(taskID: "saved_state", dryRun: false, reviewedPaths: [state.path])
            let command = await runner.runProcess("/usr/bin/touch", arguments: [marker.path])
            let batch = await runner.run(taskIDs: ["saved_state", "broken_configs"], dryRun: false)
            return (result, command.exitCode, batch.count)
        }
        let (result, code, count) = await worker.value
        if case .skipped = result.outcome {} else { Issue.record("Cancellation must be reported") }
        #expect(code != 0)
        #expect(count == 0)
        #expect(FileManager.default.fileExists(atPath: state.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
