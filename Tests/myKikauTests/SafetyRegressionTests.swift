import Testing
import Core
@testable import Features
import Foundation

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
        #expect(plan.keeping([a.path]).totalReclaimable == 10)
        #expect(plan.removing([a.path]).items.map(\.url) == [b])
    }

    @Test("directorySize counts hidden files")
    func sizeIncludesHidden() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        touch(tmp.appendingPathComponent("visible.bin"), size: 100)
        touch(tmp.appendingPathComponent(".hidden.bin"), size: 50)
        #expect(SafeFileDeleter().directorySize(tmp) == 150)
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
            mine, "\(mine).plist", "\(mine).A1B2C3D4-0000-1111-2222-333344445555.plist", "group.\(mine)",
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
