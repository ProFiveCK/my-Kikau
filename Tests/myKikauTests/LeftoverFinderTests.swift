import Testing
import Core
@testable import Features
import Foundation

@Suite("LeftoverFinder")
struct LeftoverFinderTests {
    // MARK: matchesBundleID — exact-match safety rule

    @Test("Exact bundle ID matches")
    func exactMatch() {
        let bundleID = "com.example.myapp"
        #expect(LeftoverFinder.matchesBundleID(bundleID, bundleID: bundleID) == true)
    }

    @Test("<bundleID>.<ext> form matches")
    func dottedExtensionMatches() {
        let bundleID = "com.example.myapp"
        #expect(LeftoverFinder.matchesBundleID("\(bundleID).plist", bundleID: bundleID) == true)
        #expect(LeftoverFinder.matchesBundleID("\(bundleID).json", bundleID: bundleID) == true)
        #expect(LeftoverFinder.matchesBundleID("\(bundleID).savedState", bundleID: bundleID) == true)
    }

    @Test("group.<bundleID> prefix matches")
    func groupContainerMatches() {
        let bundleID = "com.example.myapp"
        #expect(LeftoverFinder.matchesBundleID("group.\(bundleID)", bundleID: bundleID) == true)
        #expect(LeftoverFinder.matchesBundleID("group.\(bundleID).shared", bundleID: bundleID) == true)
    }

    @Test("Different bundle ID does NOT match (safety regression)")
    func differentBundleIDDoesNotMatch() {
        let bundleID = "com.example.myapp"
        #expect(LeftoverFinder.matchesBundleID("com.example.otherapp", bundleID: bundleID) == false)
        // A shorter prefix of the bundle ID must not match.
        #expect(LeftoverFinder.matchesBundleID("com.example", bundleID: bundleID) == false)
        #expect(LeftoverFinder.matchesBundleID("com.example.myap", bundleID: bundleID) == false)
    }

    @Test("Vendor prefix does NOT match (no wildcard matching)")
    func vendorPrefixDoesNotMatch() {
        let bundleID = "com.example.myapp"
        // A path named after a vendor prefix only — must not match a real app bundle ID.
        #expect(LeftoverFinder.matchesBundleID("com.example", bundleID: bundleID) == false)
        #expect(LeftoverFinder.matchesBundleID("com", bundleID: bundleID) == false)
        #expect(LeftoverFinder.matchesBundleID("example", bundleID: bundleID) == false)
    }

    @Test("Generic app name does NOT match (no generic-name matching)")
    func genericNameDoesNotMatch() {
        let bundleID = "com.example.myapp"
        #expect(LeftoverFinder.matchesBundleID("MyApp", bundleID: bundleID) == false)
        #expect(LeftoverFinder.matchesBundleID("myapp", bundleID: bundleID) == false)
        #expect(LeftoverFinder.matchesBundleID("MyApp.plist", bundleID: bundleID) == false)
    }

    // MARK: findLeftovers — no false matches against real ~/Library

    @Test("findLeftovers with a unique nonexistent bundle ID returns no false matches")
    func findLeftoversUniqueBundleIDReturnsEmpty() {
        // A bundle ID that will never exist on a real system.
        let unique = "com.mykikau.test.nonexistent.\(UUID().uuidString)"
        let results = LeftoverFinder.findLeftovers(bundleID: unique)
        #expect(results.isEmpty, "findLeftovers must not produce false matches for a nonexistent bundle ID")
    }

    // MARK: uninstallPlan

    @Test("uninstallPlan builds app + leftover plans for a fake app")
    func uninstallPlanBuildsPlans() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appURL = tmp.appendingPathComponent("FakeApp.app")
        try? FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let resource = appURL.appendingPathComponent("payload.bin")
        try? Data(count: 64).write(to: resource)

        let app = AppInventory.AppInfo(
            url: appURL,
            name: "FakeApp",
            bundleID: "com.mykikau.test.nonexistent.\(UUID().uuidString)",
            version: "1.0",
            sizeBytes: 64,
            lastModified: nil
        )

        let deleter = SafeFileDeleter()
        let (appPlan, leftoverPlan) = LeftoverFinder.uninstallPlan(app: app, deleter: deleter)

        // App plan should include the fake .app bundle.
        #expect(appPlan.items.count == 1)
        #expect(appPlan.items.first?.url == appURL)
        // Leftover plan should be empty for a unique nonexistent bundle ID.
        #expect(leftoverPlan.isEmpty)
    }

    @Test("uninstallPlan with nil bundle ID yields an empty leftover plan")
    func uninstallPlanNilBundleID() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appURL = tmp.appendingPathComponent("NoBundleApp.app")
        try? FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)

        let app = AppInventory.AppInfo(
            url: appURL, name: "NoBundleApp", bundleID: nil,
            version: nil, sizeBytes: 0, lastModified: nil
        )

        let deleter = SafeFileDeleter()
        let (appPlan, leftoverPlan) = LeftoverFinder.uninstallPlan(app: app, deleter: deleter)

        #expect(appPlan.items.count == 1)
        #expect(leftoverPlan.isEmpty)
    }
}