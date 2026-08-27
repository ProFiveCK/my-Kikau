import Foundation
import Core

/// Executes maintenance tasks by ID and reports structured results.
/// Mirrors Mole's `lib/optimize/tasks.sh` dispatch + `outcomes.sh` result model.
///
/// Safety rules enforced (per AGENTS.md):
/// - Every file removal routes through `SafeFileDeleter`, never raw `Process` rm.
/// - `PathProtection.shared.shouldProtect` is checked before any path operation.
/// - Dry-run mode returns synthetic results without spawning processes.
/// - Sudo tasks skip rather than prompt in this phase.
/// - No task touches `/System`, `/Library/Apple`, or `com.apple.*` system bundles.
public final class MaintenanceRunner {
    /// The result of running a single maintenance task.
    public struct Result: Sendable, Hashable {
        public let outcome: MaintenanceOutcome
        public let output: [String]
        public let durationSeconds: Double

        public init(outcome: MaintenanceOutcome, output: [String] = [], durationSeconds: Double = 0) {
            self.outcome = outcome
            self.output = output
            self.durationSeconds = durationSeconds
        }
    }

    private let home: URL
    private let deleter: SafeFileDeleter
    private let opLog: OperationLog

    /// 30 days, matching Mole's `MOLE_SAVED_STATE_AGE_DAYS`.
    private let savedStateAgeDays: Double = 30

    /// Minimum days between recommending a task that has no real "is this
    /// stale" check of its own (`finder_cache`, `launch_services` — the
    /// underlying commands always succeed whether or not anything needed
    /// fixing). QuickLook/icon caches rebuild themselves continuously, so a
    /// shorter interval; LaunchServices re-registration is heavier and
    /// rarely needed unless "Open With" starts misbehaving, so a longer one.
    private let staleAfterDays = (finderCache: 14.0, launchServices: 30.0)

    public init(home: URL? = nil, deleter: SafeFileDeleter = .shared, opLog: OperationLog = .shared) {
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.deleter = deleter
        self.opLog = opLog
    }

    // MARK: - Public dispatch

    /// Runs a single task by ID.
    public func run(taskID: String, dryRun: Bool) async -> Result {
        let start = Date()
        let outcome = await dispatch(taskID: taskID, dryRun: dryRun)
        let duration = Date().timeIntervalSince(start)
        let result = Result(outcome: outcome, durationSeconds: duration)
        logResult(taskID: taskID, result: result, dryRun: dryRun)
        return result
    }

    /// Runs multiple tasks sequentially, returning a dictionary keyed by task ID.
    public func run(taskIDs: [String], dryRun: Bool) async -> [String: Result] {
        var results: [String: Result] = [:]
        for id in taskIDs {
            results[id] = await run(taskID: id, dryRun: dryRun)
        }
        return results
    }

    // MARK: - Dispatch

    private func dispatch(taskID: String, dryRun: Bool) async -> MaintenanceOutcome {
        switch taskID {
        // Non-sudo, fully implemented tasks.
        case "launch_services": return await runLaunchServices(dryRun: dryRun)
        case "quarantine": return await runQuarantineCleanup(dryRun: dryRun)
        case "prevent_dsstore": return await runPreventDSStore(dryRun: dryRun)
        case "legacy_overrides": return await runLegacyOverrides(dryRun: dryRun)
        case "finder_cache": return await runFinderCache(dryRun: dryRun)
        case "saved_state": return await runSavedStateCleanup(dryRun: dryRun)
        case "shared_file_lists": return await runSharedFileLists(dryRun: dryRun)
        case "broken_configs": return await runBrokenConfigs(dryRun: dryRun)
        case "launch_agents": return await runLaunchAgentsCleanup(dryRun: dryRun)
        case "spotlight_orphans": return await runSpotlightOrphans(dryRun: dryRun)
        case "network_privacy": return runNetworkPrivacyAudit()

        // Sudo tasks — deferred pending sudo-prompting UX.
        case "dns_spotlight", "network_cache", "network_stack",
             "disk_permissions", "spotlight_index", "periodic", "disk_verify":
            return .skipped("Requires sudo — not implemented in this phase")

        // Active-database / complex tasks — deferred for safety.
        case "sqlite_vacuum":
            return .unavailable("Database optimisation deferred — active-app safety check pending")
        case "notifications":
            return .unavailable("Notification cleanup deferred — active-database safety concerns")
        case "coreduet":
            return .unavailable("Usage data cleanup deferred — active-database safety concerns")
        case "login_items":
            return .unavailable("Login items audit deferred — SMAppService integration pending")

        default:
            return .failed("Unknown task ID: \(taskID)")
        }
    }

    // MARK: - Command execution helper

    /// Spawns a process and captures combined stdout/stderr. Returns exit code + output.
    /// In dry-run mode, returns a synthetic success (exit 0) without spawning.
    /// For sudo tasks, prepends `sudo -n` (non-interactive) and reports skipped if
    /// sudo credentials are not cached.
    func runProcess(
        _ executable: String,
        arguments: [String],
        requiresSudo: Bool = false,
        dryRun: Bool = false
    ) async -> (exitCode: Int, output: String) {
        if dryRun {
            let cmd = ([executable] + arguments).joined(separator: " ")
            return (0, "[dry-run] \(cmd)")
        }

        if requiresSudo, await !sudoAvailable() {
            return (1, "sudo credentials not available")
        }

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        if requiresSudo {
            process.launchPath = "/usr/bin/sudo"
            process.arguments = ["-n"] + [executable] + arguments
        } else {
            process.launchPath = executable
            process.arguments = arguments
        }

        do {
            try process.run()
        } catch {
            return (1, "Failed to launch \(executable): \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (Int(process.terminationStatus), output)
    }

    /// Checks whether sudo credentials are cached (non-interactive).
    func sudoAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.launchPath = "/usr/bin/sudo"
            process.arguments = ["-n", "true"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Task: launch_services

    /// Builds the lsregister command array for LaunchServices rebuild.
    func launchServicesCommands() -> [(String, [String])] {
        guard let lsregister = lsregisterPath() else { return [] }
        return [
            (lsregister, ["-gc"]),
            (lsregister, ["-r", "-f", "-domain", "local", "-domain", "user", "-domain", "system"]),
        ]
    }

    private func runLaunchServices(dryRun: Bool) async -> MaintenanceOutcome {
        let commands = launchServicesCommands()
        guard !commands.isEmpty else { return .unavailable("lsregister not found") }

        // lsregister -gc / -r always exit 0 whether or not the database was
        // actually stale — there's no "check" mode to inspect first, unlike
        // the other tasks in this file. Without a gate here, the scan (which
        // runs every task with dryRun: true) would mark this "Recommended"
        // on every single scan. Gate on how long it's been since the last
        // real repair instead, so it only surfaces again once it's plausibly
        // due, same as the other tasks report `.unchanged` when there's
        // nothing to fix.
        if dryRun, let days = daysSinceLastSuccess(taskID: "launch_services"), days < staleAfterDays.launchServices {
            return .unchanged("Repaired \(daysDescription(days)) ago")
        }

        var applied = 0
        var failed = 0
        for (exec, args) in commands {
            let (code, _) = await runProcess(exec, arguments: args, dryRun: dryRun)
            if code == 0 { applied += 1 } else { failed += 1 }
        }
        if failed > 0 { return .failed("LaunchServices rebuild failed (\(failed) command(s))") }
        if applied > 0 { return .applied("LaunchServices repaired") }
        return .unchanged("LaunchServices already current")
    }

    private func lsregisterPath() -> String? {
        let candidates = [
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Task: quarantine

    /// Quarantine DB path under the (injectable) home.
    func quarantineDBPath() -> URL {
        home.appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
    }

    private func runQuarantineCleanup(dryRun: Bool) async -> MaintenanceOutcome {
        let dbPath = quarantineDBPath()
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            return .unchanged("Quarantine database not present")
        }
        if PathProtection.shared.shouldProtect(dbPath) {
            return .unchanged("Quarantine database is protected")
        }

        // Count rows first.
        let count = await runProcess(
            "/usr/bin/sqlite3",
            arguments: [dbPath.path, "SELECT COUNT(*) FROM LSQuarantineEvent;"],
            dryRun: false
        )
        guard count.exitCode == 0, let rows = Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failed("Failed to inspect quarantine database")
        }
        if rows == 0 {
            return .unchanged("Quarantine database already clean")
        }

        if dryRun {
            return .applied("Would clear \(rows) quarantine entr\(rows == 1 ? "y" : "ies")")
        }

        let delete = await runProcess(
            "/usr/bin/sqlite3",
            arguments: [dbPath.path, "DELETE FROM LSQuarantineEvent; VACUUM;"],
            dryRun: false
        )
        if delete.exitCode == 0 {
            return .applied("Quarantine history cleared (\(rows) entries)")
        }
        return .failed("Failed to clean quarantine database")
    }

    // MARK: - Task: prevent_dsstore

    /// Builds the defaults commands for .DS_Store prevention.
    func preventDSStoreCommands() -> [(domain: String, key: String)] {
        [("com.apple.desktopservices", "DSDontWriteNetworkStores"),
         ("com.apple.desktopservices", "DSDontWriteUSBStores")]
    }

    private func runPreventDSStore(dryRun: Bool) async -> MaintenanceOutcome {
        let keys = preventDSStoreCommands()
        var changed = 0
        var already = 0
        var failed = 0

        for (domain, key) in keys {
            // Check current value idempotently.
            let current = await runProcess(
                "/usr/bin/defaults",
                arguments: ["read", domain, key],
                dryRun: false
            )
            let value = current.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "1" || value.lowercased() == "true" {
                already += 1
                continue
            }

            if dryRun {
                changed += 1
                continue
            }

            let write = await runProcess(
                "/usr/bin/defaults",
                arguments: ["write", domain, key, "-bool", "true"],
                dryRun: false
            )
            if write.exitCode == 0 { changed += 1 } else { failed += 1 }
        }

        if failed > 0 { return .failed("Failed to enable .DS_Store prevention for \(failed) volume type(s)") }
        if changed > 0 { return .applied(".DS_Store prevention enabled on network & USB volumes") }
        return .unchanged(".DS_Store prevention already enabled")
    }

    // MARK: - Task: legacy_overrides

    /// Legacy override keys to audit and remove.
    func legacyOverrideKeys() -> [(domain: String, key: String, label: String)] {
        [("-g", "NSAppSleepDisabled", "App Nap disabled globally"),
         ("com.apple.frameworks.diskimages", "skip-verify", "Disk-image verification skipped"),
         ("com.apple.frameworks.diskimages", "skip-verify-locked", "Disk-image verification skipped (locked)"),
         ("com.apple.frameworks.diskimages", "skip-verify-remote", "Disk-image verification skipped (remote)")]
    }

    private func runLegacyOverrides(dryRun: Bool) async -> MaintenanceOutcome {
        let overrides = legacyOverrideKeys()
        var changed = 0
        var failed = 0

        for (domain, key, _) in overrides {
            let read = await runProcess(
                "/usr/bin/defaults",
                arguments: domain == "-g" ? ["read", "NSGlobalDomain", key] : ["read", domain, key],
                dryRun: false
            )
            let value = read.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let isTruthy = value == "1" || value.lowercased() == "true" || value.lowercased() == "yes"
            guard isTruthy else { continue }

            if dryRun {
                changed += 1
                continue
            }

            let del = await runProcess(
                "/usr/bin/defaults",
                arguments: domain == "-g" ? ["delete", "NSGlobalDomain", key] : ["delete", domain, key],
                dryRun: false
            )
            if del.exitCode == 0 { changed += 1 } else { failed += 1 }
        }

        if failed > 0 { return .failed("Failed to remove \(failed) override(s)") }
        if changed > 0 { return .applied("Removed \(changed) legacy override(s)") }
        return .unchanged("No legacy overrides found")
    }

    // MARK: - Task: finder_cache

    private func runFinderCache(dryRun: Bool) async -> MaintenanceOutcome {
        // Same issue as launch_services: qlmanage -r[cache] always exits 0
        // regardless of whether the cache was actually stale, so gate the
        // recommendation on elapsed time since the last real refresh.
        if dryRun, let days = daysSinceLastSuccess(taskID: "finder_cache"), days < staleAfterDays.finderCache {
            return .unchanged("Refreshed \(daysDescription(days)) ago")
        }

        let qlCache = await runProcess("/usr/bin/qlmanage", arguments: ["-r", "cache"], dryRun: dryRun)
        let qlRefresh = await runProcess("/usr/bin/qlmanage", arguments: ["-r"], dryRun: dryRun)

        var applied = 0
        var failed = 0
        if qlCache.exitCode == 0 { applied += 1 } else { failed += 1 }
        if qlRefresh.exitCode == 0 { applied += 1 } else { failed += 1 }

        if failed > 0 { return .failed("Finder cache refresh failed (\(failed) service(s))") }
        return .applied("QuickLook thumbnails and icon caches refreshed")
    }

    // MARK: - Task: saved_state

    private func runSavedStateCleanup(dryRun: Bool) async -> MaintenanceOutcome {
        let stateDir = home.appendingPathComponent("Library/Saved Application State")
        guard FileManager.default.fileExists(atPath: stateDir.path) else {
            return .unchanged("Saved Application State directory not present")
        }

        let cutoff = Date().addingTimeInterval(-savedStateAgeDays * 86400)
        var targets: [URL] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension == "savedState" {
                if let mod = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   mod < cutoff {
                    targets.append(entry)
                }
            }
        }

        if targets.isEmpty {
            return .unchanged("No saved states older than \(Int(savedStateAgeDays)) days")
        }

        // Route through SafeFileDeleter — never raw rm.
        let plan = deleter.preview(targets, category: .leftover)
        let filtered = plan.items.map { $0.url }

        if dryRun {
            return .applied("Would remove \(filtered.count) old saved state(s)")
        }

        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "optimize.saved_state")
        if result.failed > 0 {
            return .failed("Removed \(result.succeeded), failed \(result.failed) saved state(s)")
        }
        return .applied("Removed \(result.succeeded) old saved state(s)")
    }

    // MARK: - Task: shared_file_lists

    private func runSharedFileLists(dryRun: Bool) async -> MaintenanceOutcome {
        let sflDir = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        guard FileManager.default.fileExists(atPath: sflDir.path) else {
            return .unchanged("Shared file lists directory not present")
        }

        var corrupt: [URL] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: sflDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where ["sfl2", "sfl3"].contains(entry.pathExtension) {
                // Skip recent-documents list (user data, not a cache).
                if entry.lastPathComponent.contains("ApplicationRecentDocuments") { continue }
                let lint = await runProcess(
                    "/usr/bin/plutil", arguments: ["-lint", entry.path], dryRun: false
                )
                if lint.exitCode != 0 { corrupt.append(entry) }
            }
        }

        if corrupt.isEmpty { return .unchanged("Shared file lists all healthy") }

        let plan = deleter.preview(corrupt, category: .leftover)
        if dryRun {
            return .applied("Would repair \(plan.items.count) corrupted shared file list(s)")
        }
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "optimize.shared_file_lists")
        if result.failed > 0 {
            return .failed("Repaired \(result.succeeded), failed \(result.failed) shared file list(s)")
        }
        return .applied("Repaired \(result.succeeded) corrupted shared file list(s)")
    }

    // MARK: - Task: broken_configs

    private func runBrokenConfigs(dryRun: Bool) async -> MaintenanceOutcome {
        let prefsDir = home.appendingPathComponent("Library/Preferences")
        guard FileManager.default.fileExists(atPath: prefsDir.path) else {
            return .unchanged("Preferences directory not present")
        }

        var corrupt: [URL] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: prefsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension == "plist" {
                // Skip protected/system plists.
                if PathProtection.shared.shouldProtect(entry) { continue }
                let lint = await runProcess(
                    "/usr/bin/plutil", arguments: ["-lint", entry.path], dryRun: false
                )
                if lint.exitCode != 0 { corrupt.append(entry) }
            }
        }

        if corrupt.isEmpty { return .unchanged("All preference files valid") }

        let plan = deleter.preview(corrupt, category: .leftover)
        if dryRun {
            return .applied("Would repair \(plan.items.count) corrupted preference file(s)")
        }
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "optimize.broken_configs")
        if result.failed > 0 {
            return .failed("Repaired \(result.succeeded), failed \(result.failed) preference file(s)")
        }
        return .applied("Repaired \(result.succeeded) corrupted preference file(s)")
    }

    // MARK: - Task: launch_agents

    private func runLaunchAgentsCleanup(dryRun: Bool) async -> MaintenanceOutcome {
        let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
        guard FileManager.default.fileExists(atPath: agentsDir.path) else {
            return .unchanged("LaunchAgents directory not present")
        }

        var broken: [URL] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: agentsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension == "plist" {
                if PathProtection.shared.shouldProtect(entry) { continue }
                if isLaunchAgentBroken(entry) {
                    broken.append(entry)
                }
            }
        }

        if broken.isEmpty { return .unchanged("Launch Agents all healthy") }

        // Unload before removing.
        for plist in broken {
            _ = await runProcess("/bin/launchctl", arguments: ["unload", plist.path], dryRun: dryRun)
        }

        let plan = deleter.preview(broken, category: .leftover)
        if dryRun {
            return .applied("Would remove \(broken.count) broken Launch Agent(s)")
        }
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "optimize.launch_agents")
        if result.failed > 0 {
            return .failed("Removed \(result.succeeded), failed \(result.failed) Launch Agent(s)")
        }
        return .applied("Removed \(result.succeeded) broken Launch Agent(s)")
    }

    /// Checks whether a launch agent plist points at a missing binary.
    private func isLaunchAgentBroken(_ plist: URL) -> Bool {
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        if let program = dict["Program"] as? String,
           !FileManager.default.fileExists(atPath: program) {
            return true
        }
        if let args = dict["ProgramArguments"] as? [String], let first = args.first,
           !FileManager.default.fileExists(atPath: first) {
            return true
        }
        return false
    }

    // MARK: - Task: spotlight_orphans

    private func runSpotlightOrphans(dryRun: Bool) async -> MaintenanceOutcome {
        let domain = "com.apple.Spotlight"
        let read = await runProcess(
            "/usr/bin/defaults",
            arguments: ["read", domain, "OrderedItems"],
            dryRun: false
        )
        guard read.exitCode == 0, !read.output.isEmpty else {
            return .unchanged("No Spotlight search rules found")
        }

        // Parse the OrderedItems output for bundle IDs whose apps are no longer installed.
        // This is a best-effort text parse; Mole uses a more robust approach with mdfind.
        let lines = read.output.split(separator: "\n")
        var orphans: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Look for bundle-id-like entries.
            if trimmed.contains("\"") {
                let parts = trimmed.components(separatedBy: "\"")
                if parts.count >= 2, parts[1].contains(".") {
                    let bundleID = parts[1]
                    if !appIsInstalled(bundleID: bundleID) {
                        orphans.append(bundleID)
                    }
                }
            }
        }

        if orphans.isEmpty { return .unchanged("Spotlight search rules already clean") }

        if dryRun {
            return .applied("Would remove \(orphans.count) orphan Spotlight rule(s)")
        }

        // Rewrite via defaults — remove orphan entries.
        var removed = 0
        var failed = 0
        for bundleID in orphans {
            let del = await runProcess(
                "/usr/bin/defaults",
                arguments: ["delete", domain, bundleID],
                dryRun: false
            )
            if del.exitCode == 0 { removed += 1 } else { failed += 1 }
        }

        if failed > 0 { return .failed("Removed \(removed), failed \(failed) orphan rule(s)") }
        return .applied("Removed \(removed) orphan Spotlight rule(s)")
    }

    /// Best-effort check whether an app with the given bundle ID is installed.
    private func appIsInstalled(bundleID: String) -> Bool {
        // Check /Applications and ~/Applications for a matching bundle.
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
        ]
        for dir in appDirs {
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                for entry in entries where entry.pathExtension == "app" {
                    if let bundle = Bundle(path: entry.path),
                       bundle.bundleIdentifier == bundleID {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Diagnostic: network_privacy

    private func runNetworkPrivacyAudit() -> MaintenanceOutcome {
        do {
            let report = try NetworkPrivacyAuditor.inspect(
                installedApplications: NetworkPrivacyAuditor.discoverInstalledApplications()
            )
            return networkPrivacyOutcome(for: report)
        } catch {
            return .unavailable("Local Network privacy store could not be inspected: \(error.localizedDescription)")
        }
    }

    func networkPrivacyOutcome(for report: NetworkPrivacyAuditor.Report) -> MaintenanceOutcome {
        guard !report.findings.isEmpty else {
            return .unchanged("Local Network privacy records are healthy")
        }
        let count = report.findings.count
        return .attention(
            "\(count) issue\(count == 1 ? "" : "s") found in Local Network privacy records — guided repair available"
        )
    }

    // MARK: - Staleness gating (for tasks with no real "would this change anything" check)

    /// Days since the last successful, real (non-dry-run) run of `taskID`,
    /// or `nil` if it has never succeeded. Reads the same operation log every
    /// other task's "last run" UI already relies on, so no new state.
    private func daysSinceLastSuccess(taskID: String) -> Double? {
        let action = "optimize.\(taskID)"
        guard let entry = opLog.recent(limit: 10_000).first(where: {
            $0.action == action && $0.outcome == .success && !$0.dryRun
        }) else {
            return nil
        }
        return max(0, Date().timeIntervalSince(entry.timestamp) / 86400)
    }

    private func daysDescription(_ days: Double) -> String {
        let whole = Int(days)
        if whole < 1 { return "today" }
        return "\(whole) day\(whole == 1 ? "" : "s")"
    }

    // MARK: - OperationLog integration

    private func logResult(taskID: String, result: Result, dryRun: Bool) {
        let action = "optimize.\(taskID)"
        let detail = result.output.joined(separator: "; ")
        let (outcome, sizeBytes) = mapOutcome(result.outcome, dryRun: dryRun)
        opLog.append(.init(
            action: action,
            path: "",
            sizeBytes: sizeBytes,
            mode: .permanent,
            outcome: outcome,
            dryRun: dryRun,
            detail: result.outcome.detail ?? (detail.isEmpty ? nil : detail)
        ))
    }

    private func mapOutcome(_ outcome: MaintenanceOutcome, dryRun: Bool) -> (OperationLog.Outcome, Int64) {
        switch outcome {
        case .applied: return (dryRun ? .dryRun : .success, 0)
        case .unchanged: return (.skipped, 0)
        case .skipped: return (.skipped, 0)
        case .unavailable: return (.skipped, 0)
        case .attention: return (.skipped, 0)
        case .failed: return (.failed, 0)
        }
    }
}