import Testing
import Core
@testable import Features
import Foundation

@Suite("AppTeardown")
struct AppTeardownTests {
    private func makeHome() -> URL {
        // Resolve symlinks: temporaryDirectory returns /var/folders/... but the
        // real path is /private/var/folders/... . Directory enumeration yields
        // the resolved form, so equality checks fail unless we standardize.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.resolvingSymlinksInPath()
    }

    private func makeDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeAppInfo(url: URL, bundleID: String, name: String? = nil) -> AppInventory.AppInfo {
        AppInventory.AppInfo(
            url: url,
            name: name ?? url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            version: "1.0",
            sizeBytes: 100,
            lastModified: nil
        )
    }

    private func writePlist(_ url: URL, _ dict: NSDictionary) {
        makeDir(url.deletingLastPathComponent())
        dict.write(to: url, atomically: true)
    }

    // MARK: - LaunchAgent unload

    @Test("dry-run reports would-unload without deleting the plist")
    func launchAgentDryRunNoSpawn() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(agentsDir)
        let plist = agentsDir.appendingPathComponent("com.test.app.plist")
        writePlist(plist, ["Label": "com.test.app", "Program": "/bin/echo"])

        let app = makeAppInfo(url: URL(fileURLWithPath: "/Applications/Test.app"), bundleID: "com.test.app")
        let teardown = AppTeardown(home: home)
        let result = await teardown.teardown(app: app, dryRun: true)

        #expect(result.launchAgentsUnloaded.count == 1)
        // Compare resolved paths: contentsOfDirectory yields the resolved form.
        #expect(result.launchAgentsUnloaded.first?.0.resolvingSymlinksInPath() == plist.resolvingSymlinksInPath())
        #expect(result.launchAgentsUnloaded.first?.1 == true)
        // Dry-run must not delete the plist.
        #expect(FileManager.default.fileExists(atPath: plist.path))
    }

    @Test("com.apple.* agent labels are never unloaded")
    func appleAgentSkipped() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(agentsDir)
        let plist = agentsDir.appendingPathComponent("com.apple.dock.plist")
        writePlist(plist, ["Label": "com.apple.dock", "Program": "/bin/echo"])

        let app = makeAppInfo(url: URL(fileURLWithPath: "/Applications/Dock.app"), bundleID: "com.apple.dock")
        let teardown = AppTeardown(home: home)
        let result = await teardown.teardown(app: app, dryRun: false)

        // No user unload attempted for an Apple label.
        #expect(result.launchAgentsUnloaded.isEmpty)
    }

    @Test("agent matches by ProgramArguments referencing the app path")
    func agentMatchByAppPath() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let appPath = "/Applications/Weird/MyApp.app"
        let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
        makeDir(agentsDir)
        let plist = agentsDir.appendingPathComponent("com.unrelated.helper.plist")
        writePlist(plist, [
            "Label": "com.unrelated.helper",
            "ProgramArguments": [appPath + "/Contents/MacOS/helper"],
        ])

        let app = makeAppInfo(url: URL(fileURLWithPath: appPath), bundleID: "com.mycompany.myapp")
        let teardown = AppTeardown(home: home)
        // Dry-run so we never actually spawn launchctl.
        let result = await teardown.teardown(app: app, dryRun: true)

        #expect(result.launchAgentsUnloaded.count == 1)
        #expect(result.launchAgentsUnloaded.first?.0.resolvingSymlinksInPath() == plist.resolvingSymlinksInPath())
    }

    // MARK: - Login-item helper discovery

    @Test("discoverLoginItemHelpers returns reverse-DNS helpers, filters com.apple.*")
    func discoverHelpers() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let app = home.appendingPathComponent("MyApp.app")
        let loginItems = app.appendingPathComponent("Contents/Library/LoginItems")

        // Valid third-party helper.
        let helper = loginItems.appendingPathComponent("Helper.app")
        makeDir(helper.appendingPathComponent("Contents"))
        writePlist(helper.appendingPathComponent("Contents/Info.plist"), [
            "CFBundleIdentifier": "com.mycompany.myapp.helper",
        ])

        // Apple helper — must be filtered out.
        let appleHelper = loginItems.appendingPathComponent("AppleHelper.app")
        makeDir(appleHelper.appendingPathComponent("Contents"))
        writePlist(appleHelper.appendingPathComponent("Contents/Info.plist"), [
            "CFBundleIdentifier": "com.apple.helper",
        ])

        let teardown = AppTeardown(home: home)
        let helpers = teardown.discoverLoginItemHelpers(appURL: app)

        #expect(helpers.count == 1)
        #expect(helpers.first == "com.mycompany.myapp.helper")
    }

    @Test("dry-run reports would-bootout helpers without spawning launchctl")
    func bootoutDryRun() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let app = home.appendingPathComponent("MyApp.app")
        let loginItems = app.appendingPathComponent("Contents/Library/LoginItems")
        let helper = loginItems.appendingPathComponent("Helper.app")
        makeDir(helper.appendingPathComponent("Contents"))
        writePlist(helper.appendingPathComponent("Contents/Info.plist"), [
            "CFBundleIdentifier": "com.mycompany.myapp.helper",
        ])

        let appInfo = makeAppInfo(url: app, bundleID: "com.mycompany.myapp")
        let stub = StubLoginItemService()
        let teardown = AppTeardown(home: home, loginItemService: stub)
        let result = await teardown.teardown(app: appInfo, dryRun: true)

        #expect(result.loginItemHelpersBootedOut == ["com.mycompany.myapp.helper"])
        // Dry-run must not call the real bootout.
        #expect(stub.bootoutCalls.isEmpty)
    }

    @Test("non-dry-run calls bootoutLoginItemHelper with the helper bundle ID")
    func bootoutCallsService() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let app = home.appendingPathComponent("MyApp.app")
        let loginItems = app.appendingPathComponent("Contents/Library/LoginItems")
        let helper = loginItems.appendingPathComponent("Helper.app")
        makeDir(helper.appendingPathComponent("Contents"))
        writePlist(helper.appendingPathComponent("Contents/Info.plist"), [
            "CFBundleIdentifier": "com.mycompany.myapp.helper",
        ])

        let appInfo = makeAppInfo(url: app, bundleID: "com.mycompany.myapp")
        let stub = StubLoginItemService()
        let teardown = AppTeardown(home: home, loginItemService: stub)
        _ = await teardown.teardown(app: appInfo, dryRun: false)

        #expect(stub.bootoutCalls == ["com.mycompany.myapp.helper"])
    }

    // MARK: - Legacy login-item removal

    @Test("non-dry-run calls removeLoginItemByName with the app name (.app stripped)")
    func removeLoginItemByName() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let appURL = URL(fileURLWithPath: "/Applications/My Cool App.app")
        let appInfo = makeAppInfo(url: appURL, bundleID: "com.mycompany.mycoolapp", name: "My Cool App")
        let stub = StubLoginItemService()
        let teardown = AppTeardown(home: home, loginItemService: stub)
        _ = await teardown.teardown(app: appInfo, dryRun: false)

        #expect(stub.removeByNameCalls == ["My Cool App"])
    }

    @Test("dry-run reports login item removal without spawning osascript")
    func removeLoginItemDryRun() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let appURL = URL(fileURLWithPath: "/Applications/MyApp.app")
        let appInfo = makeAppInfo(url: appURL, bundleID: "com.mycompany.myapp", name: "MyApp")
        let stub = StubLoginItemService()
        let teardown = AppTeardown(home: home, loginItemService: stub)
        let result = await teardown.teardown(app: appInfo, dryRun: true)

        #expect(result.loginItemsRemoved == ["MyApp"])
        #expect(stub.removeByNameCalls.isEmpty)
    }

    // MARK: - LaunchServices unregister

    @Test("lsregister -u dry-run reports success without spawning")
    func lsregisterDryRun() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let app = home.appendingPathComponent("MyApp.app")
        makeDir(app)
        let appInfo = makeAppInfo(url: app, bundleID: "com.mycompany.myapp")
        let teardown = AppTeardown(home: home)
        let result = await teardown.teardown(app: appInfo, dryRun: true)

        // Dry-run sets the flag without spawning lsregister.
        // (lsregister may be absent in CI; dry-run must still report true.)
        #expect(result.unregisteredLaunchServices == true)
    }

    // MARK: - Reverse-DNS validation

    @Test("isReverseDNSBundleID rejects non-reverse-DNS values")
    func reverseDNSValidation() {
        let teardown = AppTeardown()
        #expect(teardown.isReverseDNSBundleID("com.example.app") == true)
        #expect(teardown.isReverseDNSBundleID("com.example.app.helper") == true)
        #expect(teardown.isReverseDNSBundleID("App") == false)
        #expect(teardown.isReverseDNSBundleID("not a bundle id") == false)
        #expect(teardown.isReverseDNSBundleID(".com") == false)
        #expect(teardown.isReverseDNSBundleID("com.") == false)
    }

    // MARK: - LeftoverFinder home injection

    @Test("LeftoverFinder.findLeftovers(bundleID:home:) matches exact bundle ID only")
    func leftoverFinderHomeInjection() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let appSupport = home.appendingPathComponent("Library/Application Support/com.test.app")
        makeDir(appSupport)
        let prefsPlist = home.appendingPathComponent("Library/Preferences/com.test.app.plist")
        writePlist(prefsPlist, ["key": "value"])

        // Decoy — different bundle ID, must not match.
        let decoy = home.appendingPathComponent("Library/Application Support/com.other.app")
        makeDir(decoy)

        let results = LeftoverFinder.findLeftovers(bundleID: "com.test.app", home: home)
        let paths = Set(results.map { $0.resolvingSymlinksInPath().path })
        #expect(paths.contains(appSupport.resolvingSymlinksInPath().path))
        #expect(paths.contains(prefsPlist.resolvingSymlinksInPath().path))
        #expect(!paths.contains(decoy.resolvingSymlinksInPath().path))
    }

    @Test("LeftoverFinder does not vendor-prefix match")
    func noVendorPrefixMatch() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // A directory named "com.test" must NOT match bundle ID "com.test.app".
        let similar = home.appendingPathComponent("Library/Application Support/com.test")
        makeDir(similar)
        let results = LeftoverFinder.findLeftovers(bundleID: "com.test.app", home: home)
        #expect(results.isEmpty)
    }

    // MARK: - Protected-app guard

    @Test("AppInventory.isProtected true for a system-critical bundle")
    func protectedAppDetected() {
        let app = AppInventory.AppInfo(
            url: URL(fileURLWithPath: "/System/Applications/Finder.app"),
            name: "Finder",
            bundleID: "com.apple.finder",
            version: nil,
            sizeBytes: 0,
            lastModified: nil
        )
        #expect(AppInventory.isProtected(app) == true)
    }

    @Test("AppInventory.isProtected false for a third-party app")
    func thirdPartyAppNotProtected() {
        let app = AppInventory.AppInfo(
            url: URL(fileURLWithPath: "/Applications/MyApp.app"),
            name: "MyApp",
            bundleID: "com.mycompany.myapp",
            version: nil,
            sizeBytes: 0,
            lastModified: nil
        )
        #expect(AppInventory.isProtected(app) == false)
    }

    // MARK: - Teardown result + OperationLog

    @Test("teardown logs an entry to OperationLog")
    func teardownLogsToOperationLog() async {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".log")
        let opLog = OperationLog(logURL: logURL, enabled: true)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let app = home.appendingPathComponent("MyApp.app")
        makeDir(app)
        let appInfo = makeAppInfo(url: app, bundleID: "com.mycompany.myapp")
        let teardown = AppTeardown(home: home, opLog: opLog)
        _ = await teardown.teardown(app: appInfo, dryRun: true)

        var entries: [OperationLog.Entry] = []
        for _ in 0..<20 {
            entries = opLog.recent(limit: 10)
            if !entries.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!entries.isEmpty)
        #expect(entries.first?.action == "uninstall.teardown")
        #expect(entries.first?.dryRun == true)
    }

    @Test("system LaunchAgents are reported as skipped, not unloaded")
    func systemAgentsSkipped() async {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // We can't write to /Library/LaunchAgents in a test, so this asserts
        // that when the system dir is absent the result stays clean. The real
        // sudo-skip path is exercised on a machine with system agents present.
        let app = makeAppInfo(url: URL(fileURLWithPath: "/Applications/Test.app"), bundleID: "com.test.app")
        let teardown = AppTeardown(home: home)
        let result = await teardown.teardown(app: app, dryRun: true)
        // No false-positive system skips against an empty temp home.
        #expect(result.systemLaunchAgentsSkipped.isEmpty)
    }
}