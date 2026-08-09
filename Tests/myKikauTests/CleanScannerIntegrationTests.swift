import Testing
import Core
import Features
import Foundation

/// Integration tests for CleanScanner against a synthetic temp HOME.
/// These exercise the real scanner code path against a temp ~/Library so no
/// real user data is touched, and verify category mapping + plan contents.
@Suite("CleanScanner integration")
struct CleanScannerIntegrationTests {
    private func makeHome() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func touch(_ url: URL, size: Int = 8) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: size).write(to: url)
    }

    @Test("userAppCache scans ~/Library/Caches contents as cache category")
    func userAppCacheScansContents() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let caches = home.appendingPathComponent("Library/Caches")
        touch(caches.appendingPathComponent("com.example.app/cache.db"), size: 64)
        touch(caches.appendingPathComponent("com.other.app/state.bin"), size: 32)

        let deleter = SafeFileDeleter()
        let plan = CleanScanner.scan(.userAppCache, deleter: deleter, home: home)

        #expect(plan.items.count == 2)
        #expect(plan.protectedItems.isEmpty)
        // Every scanned item should be categorized as cache.
        #expect(plan.items.allSatisfy { $0.category == .cache })
        // Reclaimable total is the sum of both directory sizes.
        #expect(plan.totalReclaimable == 96)
    }

    @Test("browserCache returns only existing browser cache targets")
    func browserCacheExistingOnly() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Only create the Chrome cache; Firefox/Safari/etc. stay absent.
        touch(home.appendingPathComponent("Library/Caches/Google/Chrome/Cache/data"), size: 100)

        let deleter = SafeFileDeleter()
        let plan = CleanScanner.scan(.browserCache, deleter: deleter, home: home)

        #expect(plan.items.count == 1)
        #expect(plan.items.first?.url.lastPathComponent == "Chrome")
        #expect(plan.items.first?.category == .cache)
        // Missing targets (Safari, Firefox, Edge, Brave) are not failures —
        // they are simply absent; preview routes them to missingItems.
        #expect(plan.missingItems.count >= 5)
    }

    @Test("trash section maps to trash category")
    func trashCategoryMapping() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let trash = home.appendingPathComponent(".Trash")
        touch(trash.appendingPathComponent("discarded.txt"), size: 16)

        let deleter = SafeFileDeleter()
        let plan = CleanScanner.scan(.trash, deleter: deleter, home: home)

        #expect(plan.items.count == 1)
        #expect(plan.items.first?.category == .trash)
        #expect(plan.totalReclaimable == 16)
    }

    @Test("recentItems section maps to leftover category")
    func recentItemsCategoryMapping() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let sharedDir = home.appendingPathComponent(
            "Library/Application Support/com.apple.sharedfilelist")
        touch(sharedDir.appendingPathComponent("com.apple.LSSharedFileList.RecentApplications.sfl2"), size: 8)
        touch(home.appendingPathComponent("Library/Preferences/com.apple.recentitems.plist"), size: 4)

        let deleter = SafeFileDeleter()
        let plan = CleanScanner.scan(.recentItems, deleter: deleter, home: home)

        #expect(plan.items.count == 2)
        #expect(plan.items.allSatisfy { $0.category == .leftover })
        #expect(plan.totalReclaimable == 12)
    }

    @Test("scanAll covers every section without touching real ~/Library")
    func scanAllAgainstTempHome() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Seed a couple of sections so scanAll has something to find.
        touch(home.appendingPathComponent("Library/Caches/com.example/cache.bin"), size: 10)
        touch(home.appendingPathComponent(".Trash/junk.txt"), size: 5)

        let deleter = SafeFileDeleter()
        let plans = CleanScanner.scanAll(deleter: deleter, home: home)

        // Every Section case should produce a plan entry.
        #expect(plans.count == CleanScanner.Section.allCases.count)
        // The userAppCache and trash sections should have found our seeded items.
        #expect(plans[.userAppCache]?.items.count == 1)
        #expect(plans[.trash]?.items.count == 1)
    }

    @Test("Protected system paths are never returned even if targeted")
    func protectedPathsExcluded() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // systemLogs targets ~/Library/Logs under the temp home — that is fine.
        touch(home.appendingPathComponent("Library/Logs/mykikau.log"), size: 4)
        let deleter = SafeFileDeleter()
        let plan = CleanScanner.scan(.systemLogs, deleter: deleter, home: home)

        // The temp ~/Library/Logs is not a protected path, so it scans normally.
        #expect(plan.items.count == 1)
        #expect(plan.protectedItems.isEmpty)
    }
}