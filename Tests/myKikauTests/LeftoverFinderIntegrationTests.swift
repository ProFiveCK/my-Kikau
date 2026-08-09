import Testing
import Core
@testable import Features
import Foundation

/// Integration tests for LeftoverFinder against a synthetic temp HOME.
/// These build a fake ~/Library with bundle-ID-named entries and verify the
/// full findLeftovers path returns exact matches — and no false matches for a
/// different bundle ID. This is the end-to-end safety regression for the
/// "exact bundle-ID only, no wildcards" rule.
@Suite("LeftoverFinder integration")
struct LeftoverFinderIntegrationTests {
    private func makeHome() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Seeds a temp ~/Library with leftovers for the given bundle ID across the
    /// standard search locations.
    private func seedLeftovers(home: URL, bundleID: String) {
        let lib = home.appendingPathComponent("Library")
        // Application Support/<bundleID>
        makeDir(lib.appendingPathComponent("Application Support/\(bundleID)"))
        // Caches/<bundleID>
        makeDir(lib.appendingPathComponent("Caches/\(bundleID)"))
        // Preferences/<bundleID>.plist — create the dir first.
        makeDir(lib.appendingPathComponent("Preferences"))
        try? Data(count: 4).write(to: lib.appendingPathComponent("Preferences/\(bundleID).plist"))
        // Logs/<bundleID>
        makeDir(lib.appendingPathComponent("Logs/\(bundleID)"))
        // Saved Application State/<bundleID>.savedState
        makeDir(lib.appendingPathComponent("Saved Application State/\(bundleID).savedState"))
        // Containers/<bundleID>
        makeDir(lib.appendingPathComponent("Containers/\(bundleID)"))
        // Group Containers/group.<bundleID>
        makeDir(lib.appendingPathComponent("Group Containers/group.\(bundleID)"))
    }

    @Test("findLeftovers finds exact bundle-ID entries across ~/Library")
    func findsExactMatches() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let bundleID = "com.mykikau.test.app.\(UUID().uuidString)"
        seedLeftovers(home: home, bundleID: bundleID)

        let results = LeftoverFinder.findLeftovers(bundleID: bundleID, home: home)

        // Expect one match per seeded location: Application Support, Caches,
        // Preferences plist, Logs, Saved Application State, Containers, Group Containers.
        #expect(results.count == 7)
        // Every result path should contain the bundle ID (exact-match semantics).
        #expect(results.allSatisfy { $0.lastPathComponent.contains(bundleID) || $0.lastPathComponent.contains("group.\(bundleID)") || $0.lastPathComponent == bundleID })
    }

    @Test("findLeftovers returns no false matches for a different bundle ID")
    func noFalseMatchesForDifferentBundleID() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let realBundleID = "com.mykikau.test.real.\(UUID().uuidString)"
        seedLeftovers(home: home, bundleID: realBundleID)

        // Query with a completely different bundle ID — must find nothing.
        let otherBundleID = "com.mykikau.test.other.\(UUID().uuidString)"
        let results = LeftoverFinder.findLeftovers(bundleID: otherBundleID, home: home)
        #expect(results.isEmpty, "findLeftovers must not match entries belonging to a different bundle ID")
    }

    @Test("findLeftovers ignores unrelated entries in the same directories")
    func ignoresUnrelatedEntries() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let bundleID = "com.mykikau.test.target.\(UUID().uuidString)"
        let lib = home.appendingPathComponent("Library")
        // Target app's leftovers.
        makeDir(lib.appendingPathComponent("Caches/\(bundleID)"))
        // Unrelated apps in the same Caches dir.
        makeDir(lib.appendingPathComponent("Caches/com.other.app"))
        makeDir(lib.appendingPathComponent("Caches/com.unrelated"))
        try? Data(count: 2).write(to: lib.appendingPathComponent("Preferences/com.other.app.plist"))

        let results = LeftoverFinder.findLeftovers(bundleID: bundleID, home: home)
        // Only the target's Caches entry should match — not the unrelated ones.
        #expect(results.count == 1)
        #expect(results.first?.lastPathComponent == bundleID)
    }

    @Test("findLeftovers returns empty for a bundle ID with no leftovers")
    func emptyWhenNoLeftovers() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Build an empty ~/Library structure.
        let lib = home.appendingPathComponent("Library")
        makeDir(lib.appendingPathComponent("Caches"))
        makeDir(lib.appendingPathComponent("Application Support"))

        let bundleID = "com.mykikau.test.empty.\(UUID().uuidString)"
        let results = LeftoverFinder.findLeftovers(bundleID: bundleID, home: home)
        #expect(results.isEmpty)
    }
}