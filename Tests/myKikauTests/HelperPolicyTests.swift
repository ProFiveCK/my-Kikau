import Testing
@testable import Core
import Foundation

/// The privileged helper runs as root and trusts nothing the app sends.
/// These pin exactly what it will and won't remove.
@Suite("HelperPolicy")
struct HelperPolicyTests {
    private let fm = FileManager.default

    /// A scratch tree standing in for `/Applications` and `/Library`.
    private func makeRoots() -> (apps: URL, library: URL, base: URL) {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let apps = base.appendingPathComponent("Applications")
        let library = base.appendingPathComponent("Library")
        for dir in [apps, library.appendingPathComponent("LaunchDaemons"),
                    library.appendingPathComponent("LaunchAgents"),
                    library.appendingPathComponent("PrivilegedHelperTools")] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (apps, library, base)
    }

    @discardableResult
    private func makeApp(_ url: URL, bundleID: String?) -> URL {
        try? fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if let bundleID {
            (["CFBundleIdentifier": bundleID] as NSDictionary)
                .write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true)
        }
        return url
    }

    private func touch(_ url: URL) -> URL {
        try? Data("x".utf8).write(to: url)
        return url
    }

    private func validate(_ url: URL, _ roots: (apps: URL, library: URL, base: URL)) -> Result<HelperPolicy.Kind, HelperPolicy.Rejection> {
        HelperPolicy.validateRemoval(path: url.path, applicationsRoot: roots.apps.path, libraryRoot: roots.library.path)
    }

    private func isRejected(_ result: Result<HelperPolicy.Kind, HelperPolicy.Rejection>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    @Test("A third-party app in Applications, or one folder below, may be removed")
    func allowsApplications() {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.base) }
        let direct = makeApp(roots.apps.appendingPathComponent("Vendor.app"), bundleID: "com.vendor.app")
        let nested = makeApp(roots.apps.appendingPathComponent("Vendor Suite/Tool.app"), bundleID: "com.vendor.tool")

        #expect(validate(direct, roots) == .success(.application))
        #expect(validate(nested, roots) == .success(.application))
    }

    @Test("System apps, security software, myKikau itself and non-bundles are refused")
    func refusesProtectedApplications() {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.base) }
        #expect(isRejected(validate(makeApp(roots.apps.appendingPathComponent("Safari.app"), bundleID: "com.apple.Safari"), roots)))
        #expect(isRejected(validate(makeApp(roots.apps.appendingPathComponent("Falcon.app"), bundleID: "com.crowdstrike.falcon.App"), roots)))
        #expect(isRejected(validate(makeApp(roots.apps.appendingPathComponent("myKikau.app"), bundleID: "com.profiveck.myKikau"), roots)))
        // No Info.plist: not an application.
        #expect(isRejected(validate(makeApp(roots.apps.appendingPathComponent("Empty.app"), bundleID: nil), roots)))
        // A plain folder or file in Applications.
        try? fm.createDirectory(at: roots.apps.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        #expect(isRejected(validate(roots.apps.appendingPathComponent("Folder"), roots)))
        #expect(isRejected(validate(touch(roots.apps.appendingPathComponent("note.txt")), roots)))
        // The Applications folder itself.
        #expect(isRejected(validate(roots.apps, roots)))
    }

    @Test("An app inside another app, or two folders down, is refused")
    func refusesDeeperPaths() {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.base) }
        makeApp(roots.apps.appendingPathComponent("Outer.app"), bundleID: "com.vendor.outer")
        let inner = makeApp(roots.apps.appendingPathComponent("Outer.app/Helper.app"), bundleID: "com.vendor.helper")
        let deep = makeApp(roots.apps.appendingPathComponent("A/B/Deep.app"), bundleID: "com.vendor.deep")

        #expect(isRejected(validate(inner, roots)))
        #expect(isRejected(validate(deep, roots)))
    }

    @Test("Third-party launch plists and helper tools may be removed; Apple's and security agents' may not")
    func launchItemsAndHelperTools() {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.base) }
        let daemons = roots.library.appendingPathComponent("LaunchDaemons")
        let agents = roots.library.appendingPathComponent("LaunchAgents")
        let tools = roots.library.appendingPathComponent("PrivilegedHelperTools")

        #expect(validate(touch(daemons.appendingPathComponent("com.vendor.daemon.plist")), roots) == .success(.launchItem))
        #expect(validate(touch(agents.appendingPathComponent("com.vendor.agent.plist")), roots) == .success(.launchItem))
        #expect(validate(touch(tools.appendingPathComponent("com.vendor.helper")), roots) == .success(.helperTool))

        #expect(isRejected(validate(touch(daemons.appendingPathComponent("com.apple.something.plist")), roots)))
        #expect(isRejected(validate(touch(daemons.appendingPathComponent("com.sentinelone.sentineld.plist")), roots)))
        #expect(isRejected(validate(touch(daemons.appendingPathComponent("com.profiveck.myKikau.helper.plist")), roots)))
        #expect(isRejected(validate(touch(tools.appendingPathComponent("com.jamf.management.daemon")), roots)))
        // Not a plist, not named after an identifier, or a folder.
        #expect(isRejected(validate(touch(daemons.appendingPathComponent("com.vendor.daemon.sh")), roots)))
        #expect(isRejected(validate(touch(daemons.appendingPathComponent("daemon.plist")), roots)))
        try? fm.createDirectory(at: daemons.appendingPathComponent("com.vendor.dir.plist"), withIntermediateDirectories: true)
        #expect(isRejected(validate(daemons.appendingPathComponent("com.vendor.dir.plist"), roots)))
    }

    @Test("Anything outside the three locations is refused")
    func refusesEverythingElse() {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.base) }
        let stray = touch(roots.library.appendingPathComponent("com.vendor.stray.plist"))
        let elsewhere = makeApp(roots.base.appendingPathComponent("Elsewhere/Vendor.app"), bundleID: "com.vendor.app")

        #expect(isRejected(validate(stray, roots)))
        #expect(isRejected(validate(elsewhere, roots)))
        for path in ["/etc/hosts", "/System/Library", "/", "/Users", "relative/path", "", "/Library/Keychains/System.keychain"] {
            #expect(isRejected(HelperPolicy.validateRemoval(path: path)), "\(path) must be refused")
        }
    }

    @Test("Symbolic links and non-canonical paths are refused")
    func refusesLinksAndTricks() throws {
        let roots = makeRoots()
        defer { try? fm.removeItem(at: roots.base) }
        let real = makeApp(roots.apps.appendingPathComponent("Real.app"), bundleID: "com.vendor.real")
        let outside = makeApp(roots.base.appendingPathComponent("Outside/Target.app"), bundleID: "com.vendor.target")

        // A link in Applications pointing at something elsewhere.
        let link = roots.apps.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(isRejected(validate(link, roots)))

        // A linked folder leading into Applications.
        let alias = roots.base.appendingPathComponent("Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: roots.apps)
        #expect(isRejected(HelperPolicy.validateRemoval(
            path: alias.appendingPathComponent("Real.app").path,
            applicationsRoot: alias.path, libraryRoot: roots.library.path
        )))

        // ".." and trailing-slash spellings of an otherwise valid path.
        let dotted = roots.apps.path + "/Sub/../Real.app"
        #expect(isRejected(HelperPolicy.validateRemoval(path: dotted, applicationsRoot: roots.apps.path, libraryRoot: roots.library.path)))
        #expect(isRejected(HelperPolicy.validateRemoval(path: real.path + "/", applicationsRoot: roots.apps.path, libraryRoot: roots.library.path)))
        // The plain path is fine.
        #expect(validate(real, roots) == .success(.application))
    }

    @Test("The real system locations behave the same way")
    func realLocations() {
        // Whatever is installed here, Apple's apps and the folder itself are off limits.
        #expect(isRejected(HelperPolicy.validateRemoval(path: "/Applications")))
        #expect(isRejected(HelperPolicy.validateRemoval(path: "/Applications/Safari.app")))
        #expect(isRejected(HelperPolicy.validateRemoval(path: "/Library/LaunchDaemons")))
        #expect(isRejected(HelperPolicy.validateRemoval(path: "/Applications/DoesNotExist-\(UUID().uuidString).app")))
    }
}
