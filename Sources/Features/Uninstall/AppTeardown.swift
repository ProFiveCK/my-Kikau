import Foundation
import Core

/// Pre-deletion teardown for a third-party app.
///
/// Mirrors Mole's `stop_launch_services`, `bootout_login_item_helpers`,
/// `remove_login_item`, and `unregister_app_bundle` (from
/// `lib/uninstall/batch.sh`). Teardown only stops services so the subsequent
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

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        deleter: SafeFileDeleter = .shared,
        opLog: OperationLog = .shared,
        loginItemService: LoginItemManaging = SystemEventsLoginItemService()
    ) {
        self.home = home
        self.deleter = deleter
        self.opLog = opLog
        self.loginItemService = loginItemService
    }

    /// Per-step outcome of a teardown run.
    public struct TeardownResult {
        public var launchAgentsUnloaded: [(URL, Bool)] = []
        public var systemLaunchAgentsSkipped: [URL] = []
        public var loginItemHelpersBootedOut: [String] = []
        public var loginItemsRemoved: [String] = []
        public var unregisteredLaunchServices: Bool = false
        public var errors: [String] = []

        public init() {}
    }

    /// Runs the full teardown for one app.
    public func teardown(app: AppInventory.AppInfo, dryRun: Bool) async -> TeardownResult {
        var result = TeardownResult()
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

    /// Matches an agent plist by filename (contains bundle ID) or by
    /// `Program`/`ProgramArguments` referencing the app path. Mirrors Mole's
    /// `_uninstall_unload_launch_plists` bundle-id + app-path scan.
    public func matchesAgent(_ plist: URL, bundleID: String, appPath: String) -> Bool {
        let name = plist.lastPathComponent
        if !bundleID.isEmpty {
            // Exact `<bundleID>.plist` or `<bundleID>.<x>.plist`.
            if name == "\(bundleID).plist" { return true }
            if name.hasPrefix("\(bundleID).") && name.hasSuffix(".plist") { return true }
        }
        // App-path reference inside the plist body.
        if let data = try? Data(contentsOf: plist),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil
           ),
           let dict = plist as? [String: Any] {
            if let program = dict["Program"] as? String, program.contains(appPath) {
                return true
            }
            if let args = dict["ProgramArguments"] as? [String] {
                if args.contains(where: { $0.contains(appPath) }) { return true }
            }
        }
        return false
    }

    private func launchctlUnload(_ plist: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.launchPath = "/bin/launchctl"
            process.arguments = ["unload", plist.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                // Non-zero can mean not loaded — treat as success (idempotent).
                continuation.resume(returning: true)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - 2. Bootout login-item helpers

    /// Discovers helper bundle IDs from `<app>/Contents/Library/LoginItems/*.app`.
    /// Mirrors Mole's `discover_login_item_helper_bundle_ids`. Filters out
    /// `com.apple.*` IDs and non-reverse-DNS values.
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
                  !isAppleLabel(id) else {
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
        // Mole strips the `.app` suffix; login items are registered by name.
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

    /// Resolves the `lsregister` binary path. Mirrors Mole's
    /// `get_lsregister_path`.
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
        let process = Process()
        process.launchPath = lsregister
        process.arguments = ["-u", app.url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            result.unregisteredLaunchServices = true
        } catch {
            result.errors.append("LaunchServices unregister failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Logging

    private func logTeardown(app: AppInventory.AppInfo, result: TeardownResult, dryRun: Bool) {
        let summary = "agents=\(result.launchAgentsUnloaded.count) helpers=\(result.loginItemHelpersBootedOut.count) loginItems=\(result.loginItemsRemoved.count) ls=\(result.unregisteredLaunchServices) errors=\(result.errors.count)"
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

    /// Reverse-DNS validation mirroring Mole's `mole_is_reverse_dns_bundle_id`.
    public func isReverseDNSBundleID(_ id: String) -> Bool {
        guard id.contains("."), !id.hasPrefix("."), !id.hasSuffix(".") else { return false }
        let labels = id.split(separator: ".")
        guard labels.count >= 2 else { return false }
        // Each label must be non-empty and contain no whitespace.
        return labels.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }
}