import Foundation
import Core

/// Pre-deletion teardown for a third-party app.
///
/// Teardown only stops services so the subsequent
/// `SafeFileDeleter.execute` is clean; it never deletes files itself.
///
/// Safety rules:
///   - `com.apple.*` labels are never unloaded or booted out.
///   - System `/Library/LaunchAgents` + `/Library/LaunchDaemons` require sudo
///     and are skipped in this phase (deferred like the Optimize sudo tasks).
///   - Dry-run reports would-actions without spawning `launchctl`,
///     `osascript`, or `lsregister`.
public final class AppTeardown {
    private let home: URL
    private let deleter: SafeFileDeleter
    private let opLog: OperationLog
    private let loginItemService: LoginItemManaging
    private let otherCopies: (AppInventory.AppInfo) -> [URL]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        deleter: SafeFileDeleter = .shared,
        opLog: OperationLog = .shared,
        loginItemService: LoginItemManaging = SystemEventsLoginItemService(),
        otherCopies: @escaping (AppInventory.AppInfo) -> [URL] = { AppInventory.otherCopies(of: $0) }
    ) {
        self.home = home
        self.deleter = deleter
        self.opLog = opLog
        self.loginItemService = loginItemService
        self.otherCopies = otherCopies
    }

    /// Per-step outcome of a teardown run.
    public struct TeardownResult {
        public var launchAgentsUnloaded: [(URL, Bool)] = []
        public var systemLaunchAgentsSkipped: [URL] = []
        public var loginItemHelpersBootedOut: [String] = []
        public var loginItemsRemoved: [String] = []
        public var unregisteredLaunchServices: Bool = false
        /// Background services were left alone because another copy of the
        /// app (same bundle ID) is still installed.
        public var skippedBecauseOtherCopyInstalled: Bool = false
        public var errors: [String] = []

        public init() {}
    }

    /// Runs the full teardown for one app.
    public func teardown(app: AppInventory.AppInfo, dryRun: Bool) async -> TeardownResult {
        var result = TeardownResult()
        // Agents are matched by bundle ID and the login item by display
        // name. If another copy of the app is installed, those belong to it
        // as well — leave them running.
        if !otherCopies(app).isEmpty {
            result.skippedBecauseOtherCopyInstalled = true
            unregisterFromLaunchServices(app: app, dryRun: dryRun, result: &result)
            logTeardown(app: app, result: result, dryRun: dryRun)
            return result
        }
        await unloadLaunchAgents(for: app, dryRun: dryRun, result: &result)
        bootoutLoginItemHelpers(for: app, dryRun: dryRun, result: &result)
        removeLoginItem(for: app, dryRun: dryRun, result: &result)
        unregisterFromLaunchServices(app: app, dryRun: dryRun, result: &result)
        logTeardown(app: app, result: result, dryRun: dryRun)
        return result
    }

    // MARK: - 1. LaunchAgents / LaunchDaemons

    /// User launch-agents dir under the (injectable) home.
    public func userLaunchAgentsURL() -> URL {
        home.appendingPathComponent("Library/LaunchAgents")
    }

    /// System launch locations requiring sudo (skipped in this phase).
    public static let systemLaunchPaths: [String] = [
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
    ]

    private func unloadLaunchAgents(
        for app: AppInventory.AppInfo,
        dryRun: Bool,
        result: inout TeardownResult
    ) async {
        let bundleID = app.bundleID ?? ""
        let appPath = app.url.path

        // User LaunchAgents — no sudo.
        let userDir = userLaunchAgentsURL()
        if FileManager.default.fileExists(atPath: userDir.path) {
            await unloadMatchingAgents(
                in: userDir,
                bundleID: bundleID,
                appPath: appPath,
                dryRun: dryRun,
                result: &result
            )
        }

        // System LaunchAgents/Daemons — require sudo, skipped this phase.
        for path in Self.systemLaunchPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for entry in entries where entry.pathExtension == "plist" {
                    if matchesAgent(entry, bundleID: bundleID, appPath: appPath) {
                        result.systemLaunchAgentsSkipped.append(entry)
                    }
                }
            }
        }
    }

    private func unloadMatchingAgents(
        in dir: URL,
        bundleID: String,
        appPath: String,
        dryRun: Bool,
        result: inout TeardownResult
    ) async {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where entry.pathExtension == "plist" {
            guard matchesAgent(entry, bundleID: bundleID, appPath: appPath) else { continue }
            // Never unload Apple-managed labels.
            if isAppleLabel(entry.lastPathComponent) {
                continue
            }
            if dryRun {
                result.launchAgentsUnloaded.append((entry, true))
                continue
            }
            let ok = await launchctlUnload(entry)
            result.launchAgentsUnloaded.append((entry, ok))
            if !ok {
                result.errors.append("Failed to unload \(entry.path)")
            }
        }
    }

    /// Matches an agent plist by exact filename (`<bundleID>.plist`) or by
    /// a `Program`/`ProgramArguments` entry that is a path inside the app bundle. A longer
    /// label that merely starts with the bundle ID belongs to a different
    /// app and is not matched.
    public func matchesAgent(_ plist: URL, bundleID: String, appPath: String) -> Bool {
        let name = plist.lastPathComponent
        if !bundleID.isEmpty, name == "\(bundleID).plist" {
            return true
        }
        // App-path reference inside the plist body.
        guard !appPath.isEmpty,
              let data = try? Data(contentsOf: plist),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let dict = plist as? [String: Any] else { return false }
        func isInsideApp(_ path: String) -> Bool {
            path == appPath || path.hasPrefix(appPath + "/")
        }
        if let program = dict["Program"] as? String, isInsideApp(program) {
            return true
        }
        if let args = dict["ProgramArguments"] as? [String], args.contains(where: isInsideApp) {
            return true
        }
        return false
    }

    private func launchctlUnload(_ plist: URL) async -> Bool {
        let output = await ProcessRunner.run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist.path])
        // Non-zero can mean not loaded — treat as success (idempotent). Only
        // failing to run launchctl at all is a real failure.
        return !output.launchFailed && !output.timedOut
    }

    // MARK: - 2. Bootout login-item helpers

    /// Discovers helper bundle IDs from `<app>/Contents/Library/LoginItems/*.app`.
    /// Filters out `com.apple.*` IDs and non-reverse-DNS values.
    public func discoverLoginItemHelpers(appURL: URL) -> [String] {
        let loginItemsRoot = appURL.appendingPathComponent("Contents/Library/LoginItems")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: loginItemsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var helperIDs: [String] = []
        for entry in entries where entry.pathExtension == "app" {
            let info = entry.appendingPathComponent("Contents/Info.plist")
            guard FileManager.default.fileExists(atPath: info.path) else { continue }
            guard let bundle = Bundle(path: entry.path),
                  let id = bundle.bundleIdentifier,
                  isReverseDNSBundleID(id),
                  !isAppleLabel(id)
            else {
                continue
            }
            helperIDs.append(id)
        }
        return helperIDs
    }

    private func bootoutLoginItemHelpers(
        for app: AppInventory.AppInfo,
        dryRun: Bool,
        result: inout TeardownResult
    ) {
        let helpers = discoverLoginItemHelpers(appURL: app.url)
        for helperID in helpers {
            if dryRun {
                result.loginItemHelpersBootedOut.append(helperID)
                continue
            }
            if loginItemService.bootoutLoginItemHelper(bundleID: helperID) {
                result.loginItemHelpersBootedOut.append(helperID)
            } else {
                result.errors.append("Failed to bootout login-item helper \(helperID)")
            }
        }
    }

    // MARK: - 3. Remove legacy login items

    private func removeLoginItem(
        for app: AppInventory.AppInfo,
        dryRun: Bool,
        result: inout TeardownResult
    ) {
        // Strip the `.app` suffix; login items are registered by name.
        let cleanName = app.name.hasSuffix(".app")
            ? String(app.name.dropLast(4))
            : app.name
        guard !cleanName.isEmpty else { return }
        if dryRun {
            result.loginItemsRemoved.append(cleanName)
            return
        }
        if loginItemService.removeLoginItemByName(cleanName) {
            result.loginItemsRemoved.append(cleanName)
        }
    }

    // MARK: - 4. Unregister from LaunchServices

    /// Resolves the `lsregister` binary path.
    public func lsregisterPath() -> String? {
        let candidates = [
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func unregisterFromLaunchServices(
        app: AppInventory.AppInfo,
        dryRun: Bool,
        result: inout TeardownResult
    ) {
        guard app.url.pathExtension == "app" else { return }
        guard let lsregister = lsregisterPath() else {
            result.errors.append("lsregister not found; skipped LaunchServices unregister")
            return
        }
        if dryRun {
            result.unregisteredLaunchServices = true
            return
        }
        let output = ProcessRunner.runBlocking(lsregister, ["-u", app.url.path])
        if output.launchFailed {
            result.errors.append("LaunchServices unregister failed: \(output.stderr)")
        } else {
            result.unregisteredLaunchServices = true
        }
    }

    // MARK: - Logging

    private func logTeardown(app: AppInventory.AppInfo, result: TeardownResult, dryRun: Bool) {
        let summary = [
            "agents=\(result.launchAgentsUnloaded.count)",
            "helpers=\(result.loginItemHelpersBootedOut.count)",
            "loginItems=\(result.loginItemsRemoved.count)",
            "ls=\(result.unregisteredLaunchServices)",
            "errors=\(result.errors.count)",
        ].joined(separator: " ")
        opLog.append(.init(
            action: "uninstall.teardown",
            path: app.url.path,
            sizeBytes: 0,
            mode: .trash,
            outcome: result.errors.isEmpty ? (dryRun ? .dryRun : .success) : .failed,
            dryRun: dryRun,
            detail: summary
        ))
    }

    // MARK: - Helpers

    /// True for `com.apple.*` labels — never unload or boot out.
    public func isAppleLabel(_ id: String) -> Bool {
        id.hasPrefix("com.apple.")
    }

    /// Reverse-DNS validation for a bundle identifier.
    public func isReverseDNSBundleID(_ id: String) -> Bool {
        guard id.contains("."), !id.hasPrefix("."), !id.hasSuffix(".") else { return false }
        let labels = id.split(separator: ".")
        guard labels.count >= 2 else { return false }
        // Each label must be non-empty and contain no whitespace.
        return labels.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }
}
