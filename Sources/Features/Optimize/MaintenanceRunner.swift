import Foundation
import Core

/// Executes maintenance tasks by ID and reports structured results.
///
/// Safety rules enforced (per AGENTS.md):
/// - Every file removal routes through `SafeFileDeleter`, never raw `Process` rm,
///   and reports the exact paths in `Result.output` before anything is removed.
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

    /// Paths the task in hand would remove (dry run) or did remove, surfaced
    /// in `Result.output` so the user sees exactly which files a task touches
    /// before confirming it. Reset at the start of every `run`.
    private var details: [String] = []
    private var reviewedPaths: Set<String>?
    private var inspectionError: String?
    public private(set) var networkPrivacyReport: NetworkPrivacyAuditor.Report?
    /// Most recent successful real run per action, read from the operation
    /// log once per scan instead of once per task.
    private var lastSuccessCache: [String: Date]?

    /// Saved states untouched for this long are considered stale.
    private let savedStateAgeDays: Double = 30

    /// Minimum days between recommending a task that has no real "is this
    /// stale" check of its own (`finder_cache`, `launch_services` — the
    /// underlying commands always succeed whether or not anything needed
    /// fixing). QuickLook/icon caches rebuild themselves continuously, so a
    /// shorter interval; LaunchServices re-registration is heavier and
    /// rarely needed unless "Open With" starts misbehaving, so a longer one.
    private let staleAfterDays = (finderCache: 14.0, launchServices: 30.0, fontCache: 30.0)

    public init(home: URL? = nil, deleter: SafeFileDeleter = .shared, opLog: OperationLog = .shared) {
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.deleter = deleter
        self.opLog = opLog
    }

    // MARK: - Public dispatch

    /// Runs a single task by ID.
    public func run(taskID: String, dryRun: Bool, reviewedPaths: Set<String>? = nil) async -> Result {
        let start = Date()
        details = []
        self.reviewedPaths = reviewedPaths
        inspectionError = nil
        let detected: MaintenanceOutcome = if Task.isCancelled {
            .skipped("Cancelled")
        } else {
            await dispatch(taskID: taskID, dryRun: dryRun)
        }
        let outcome: MaintenanceOutcome = if let inspectionError {
            .unavailable(inspectionError)
        } else if dryRun, case let .applied(detail) = detected {
            .recommended(detail)
        } else {
            detected
        }
        let duration = Date().timeIntervalSince(start)
        let result = Result(outcome: outcome, output: details, durationSeconds: duration)
        logResult(taskID: taskID, result: result, dryRun: dryRun)
        if !dryRun {
            lastSuccessCache = nil
        }
        return result
    }

    /// Runs multiple tasks sequentially, returning a dictionary keyed by task ID.
    public func run(taskIDs: [String], dryRun: Bool) async -> [String: Result] {
        var results: [String: Result] = [:]
        for id in taskIDs {
            if Task.isCancelled {
                break
            }
            results[id] = await run(taskID: id, dryRun: dryRun)
        }
        return results
    }

    // MARK: - Dispatch

    private func dispatch(taskID: String, dryRun: Bool) async -> MaintenanceOutcome {
        switch taskID {
        // Non-sudo, fully implemented tasks.
        case "launch_services": await runLaunchServices(dryRun: dryRun)
        case "prevent_dsstore": await runPreventDSStore(dryRun: dryRun)
        case "legacy_overrides": await runLegacyOverrides(dryRun: dryRun)
        case "finder_cache": await runFinderCache(dryRun: dryRun)
        case "font_cache": await runFontCache(dryRun: dryRun)
        case "saved_state": await runSavedStateCleanup(dryRun: dryRun)
        case "shared_file_lists": await runSharedFileLists(dryRun: dryRun)
        case "broken_configs": await runBrokenConfigs(dryRun: dryRun)
        case "launch_agents": await runLaunchAgentsCleanup(dryRun: dryRun)
        case "network_privacy": runNetworkPrivacyAudit()
        // Sudo tasks — deferred pending sudo-prompting UX.
        case "dns_spotlight", "network_cache", "network_stack",
             "disk_permissions", "spotlight_index", "periodic", "disk_verify":
            .skipped("Requires sudo — not implemented in this phase")
        // Retired: both edited live system databases/preferences in place,
        // outside the deletion funnel and with no way to undo.
        case "quarantine":
            .unavailable("Removed — the quarantine history is a live system database and a security record")
        case "spotlight_orphans":
            .unavailable("Removed — Spotlight preferences are system-managed")
        // Active-database / complex tasks — deferred for safety.
        case "sqlite_vacuum":
            .unavailable("Database optimisation deferred — active-app safety check pending")
        case "notifications":
            .unavailable("Notification cleanup deferred — active-database safety concerns")
        case "coreduet":
            .unavailable("Usage data cleanup deferred — active-database safety concerns")
        case "login_items":
            .unavailable("Login items audit deferred — SMAppService integration pending")
        default:
            .failed("Unknown task ID: \(taskID)")
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
        guard !Task.isCancelled else { return (1, "Cancelled") }
        if dryRun {
            let cmd = ([executable] + arguments).joined(separator: " ")
            return (0, "[dry-run] \(cmd)")
        }

        if requiresSudo, await !sudoAvailable() {
            return (1, "sudo credentials not available")
        }

        let output: ProcessRunner.Output = if requiresSudo {
            await ProcessRunner.run("/usr/bin/sudo", ["-n", executable] + arguments, timeout: 120)
        } else {
            await ProcessRunner.run(executable, arguments, timeout: 120)
        }
        if output.launchFailed {
            return (1, "Failed to launch \(executable): \(output.stderr)")
        }
        if output.timedOut {
            return (1, "\(executable) timed out")
        }
        return (Int(output.exitCode), output.stdout + output.stderr)
    }

    /// Checks whether sudo credentials are cached (non-interactive).
    func sudoAvailable() async -> Bool {
        await ProcessRunner.run("/usr/bin/sudo", ["-n", "true"], timeout: 10).succeeded
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
            if code == 0 {
                applied += 1
            } else {
                failed += 1
            }
        }
        if failed > 0 {
            return .failed("LaunchServices rebuild failed (\(failed) command(s))")
        }
        if applied > 0 {
            return .applied("LaunchServices repaired")
        }
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
            if write.exitCode == 0 {
                changed += 1
            } else {
                failed += 1
            }
        }

        if failed > 0 {
            return .failed("Failed to enable .DS_Store prevention for \(failed) volume type(s)")
        }
        if changed > 0 {
            return .applied(".DS_Store prevention enabled on network & USB volumes")
        }
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
            if del.exitCode == 0 {
                changed += 1
            } else {
                failed += 1
            }
        }

        if failed > 0 {
            return .failed("Failed to remove \(failed) override(s)")
        }
        if changed > 0 {
            return .applied("Removed \(changed) legacy override(s)")
        }
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
        if qlCache.exitCode == 0 {
            applied += 1
        } else {
            failed += 1
        }
        if qlRefresh.exitCode == 0 {
            applied += 1
        } else {
            failed += 1
        }

        if failed > 0 {
            return .failed("Finder cache refresh failed (\(failed) service(s))")
        }
        return .applied("QuickLook thumbnails and icon caches refreshed")
    }

    // MARK: - Task: font_cache

    /// `atsutil databases -removeUser` clears the current user's font
    /// registration cache (the system rebuilds it on demand). No sudo needed —
    /// unlike `-remove`, which touches the system-wide cache. Like
    /// `finder_cache`/`launch_services` there's no "is it stale" probe: the
    /// command always exits 0, so gate the recommendation on elapsed time
    /// since the last real run instead of surfacing it on every scan.
    private func runFontCache(dryRun: Bool) async -> MaintenanceOutcome {
        let atsutil = "/usr/bin/atsutil"
        guard FileManager.default.isExecutableFile(atPath: atsutil) else {
            return .unavailable("atsutil not found")
        }
        if dryRun, let days = daysSinceLastSuccess(taskID: "font_cache"), days < staleAfterDays.fontCache {
            return .unchanged("Reset \(daysDescription(days)) ago")
        }

        let (code, output) = await runProcess(atsutil, arguments: ["databases", "-removeUser"], dryRun: dryRun)
        if code == 0 {
            return .applied("User font cache cleared — it rebuilds automatically")
        }
        return .failed("Font cache reset failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // MARK: - Task: saved_state

    private func runSavedStateCleanup(dryRun: Bool) async -> MaintenanceOutcome {
        let stateDir = home.appendingPathComponent("Library/Saved Application State")
        guard FileManager.default.fileExists(atPath: stateDir.path) else {
            return .unchanged("Saved Application State directory not present")
        }

        let cutoff = Date().addingTimeInterval(-savedStateAgeDays * 86400)
        var targets: [URL] = []
        if let entries = inspectionDirectory(
            at: stateDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension == "savedState" {
                if let mod = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   mod < cutoff
                {
                    targets.append(entry)
                }
            }
        }

        if targets.isEmpty {
            return .unchanged("No saved states older than \(Int(savedStateAgeDays)) days")
        }

        // Route through SafeFileDeleter — never raw rm.
        if let inspectionError {
            return .unavailable(inspectionError)
        }
        let plan = deleter.preview(targets, category: .leftover)
        guard !plan.items.isEmpty else {
            return .unchanged("No removable saved states older than \(Int(savedStateAgeDays)) days")
        }
        details = plan.items.map(\.url.path)

        if dryRun {
            return .applied("Would remove \(plan.items.count) old saved state(s)")
        }

        guard let reviewedPaths, Set(plan.items.map(\.id)).isSubset(of: reviewedPaths) else {
            return .failed("The files changed after review. Scan and review this task again.")
        }
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "optimize.saved_state", isCancelled: { Task.isCancelled })
        if result.cancelled {
            return .skipped("Stopped after removing \(result.succeeded) saved state(s)")
        }
        if result.skipped > 0 {
            return .skipped("Some saved states became protected; scan again")
        }
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
        if let entries = inspectionDirectory(
            at: sflDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where ["sfl2", "sfl3"].contains(entry.pathExtension) {
                // Skip recent-documents list (user data, not a cache).
                if entry.lastPathComponent.contains("ApplicationRecentDocuments") {
                    continue
                }
                if !isValidPropertyList(entry) {
                    corrupt.append(entry)
                }
            }
        }

        if corrupt.isEmpty {
            return .unchanged("Shared file lists all healthy")
        }

        if let inspectionError {
            return .unavailable(inspectionError)
        }
        let plan = deleter.preview(corrupt, category: .leftover)
        guard !plan.items.isEmpty else { return .unchanged("Shared file lists all healthy") }
        details = plan.items.map(\.url.path)
        if dryRun {
            return .applied("Would repair \(plan.items.count) corrupted shared file list(s)")
        }
        guard let reviewedPaths, Set(plan.items.map(\.id)).isSubset(of: reviewedPaths) else {
            return .failed("The files changed after review. Scan and review this task again.")
        }
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "optimize.shared_file_lists", isCancelled: { Task.isCancelled })
        if result.cancelled {
            return .skipped("Stopped after repairing \(result.succeeded) shared file list(s)")
        }
        if result.skipped > 0 {
            return .skipped("Some shared file lists became protected; scan again")
        }
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
        if let entries = inspectionDirectory(
            at: prefsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let recentlyWritten = Date().addingTimeInterval(-60)
            for entry in entries where entry.pathExtension == "plist" {
                // Skip protected plists and anything macOS itself owns.
                if PathProtection.shared.shouldProtect(entry) {
                    continue
                }
                if entry.lastPathComponent.hasPrefix("com.apple.") || entry.lastPathComponent.hasPrefix(".") {
                    continue
                }
                // cfprefsd rewrites preference files in place; one that's
                // mid-write can look corrupt for a moment.
                if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified > recentlyWritten
                {
                    continue
                }
                if !isValidPropertyList(entry) {
                    corrupt.append(entry)
                }
            }
        }

        if corrupt.isEmpty {
            return .unchanged("All preference files valid")
        }

        if let inspectionError {
            return .unavailable(inspectionError)
        }
        let plan = deleter.preview(corrupt, category: .leftover)
        guard !plan.items.isEmpty else { return .unchanged("All preference files valid") }
        details = plan.items.map(\.url.path)
        if dryRun {
            return .applied("Would repair \(plan.items.count) corrupted preference file(s)")
        }
        guard let reviewedPaths, Set(plan.items.map(\.id)).isSubset(of: reviewedPaths) else {
            return .failed("The files changed after review. Scan and review this task again.")
        }
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "optimize.broken_configs", isCancelled: { Task.isCancelled })
        if result.cancelled {
            return .skipped("Stopped after repairing \(result.succeeded) preference file(s)")
        }
        if result.skipped > 0 {
            return .skipped("Some preferences became protected; scan again")
        }
        if result.failed > 0 {
            return .failed("Repaired \(result.succeeded), failed \(result.failed) preference file(s)")
        }
        return .applied("Repaired \(result.succeeded) corrupted preference file(s)")
    }

    /// True if the file parses as a property list (any format). Done
    /// in-process — no `plutil` subprocess per file.
    private func inspectionDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions
    ) -> [URL]? {
        do { return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options) }
        catch { inspectionError = "Couldn’t inspect \(url.path): \(error.localizedDescription)"; return nil }
    }

    private func isValidPropertyList(_ url: URL) -> Bool {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch {
            inspectionError = "Couldn’t read \(url.path): \(error.localizedDescription)"
            return true // Unreadable is never evidence of corruption.
        }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil
    }

    // MARK: - Task: launch_agents

    private func runLaunchAgentsCleanup(dryRun: Bool) async -> MaintenanceOutcome {
        let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
        guard FileManager.default.fileExists(atPath: agentsDir.path) else {
            return .unchanged("LaunchAgents directory not present")
        }

        var broken: [URL] = []
        if let entries = inspectionDirectory(
            at: agentsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension == "plist" {
                if PathProtection.shared.shouldProtect(entry) {
                    continue
                }
                if isLaunchAgentBroken(entry) {
                    broken.append(entry)
                }
            }
        }

        if broken.isEmpty {
            return .unchanged("Launch Agents all healthy")
        }

        if let inspectionError {
            return .unavailable(inspectionError)
        }
        let plan = deleter.preview(broken, category: .leftover)
        guard !plan.items.isEmpty else { return .unchanged("Launch Agents all healthy") }
        details = plan.items.map(\.url.path)
        if dryRun {
            return .applied("Would remove \(plan.items.count) broken Launch Agent(s)")
        }

        // Unload before removing.
        guard let reviewedPaths, Set(plan.items.map(\.id)).isSubset(of: reviewedPaths) else {
            return .failed("The files changed after review. Scan and review this task again.")
        }
        for item in plan.items {
            guard !Task.isCancelled else { return .skipped("Cancelled before removing Launch Agents") }
            _ = await runProcess("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", item.url.path], dryRun: false)
        }

        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "optimize.launch_agents", isCancelled: { Task.isCancelled })
        if result.cancelled {
            return .skipped("Stopped after removing \(result.succeeded) Launch Agent(s)")
        }
        if result.skipped > 0 {
            return .skipped("Some Launch Agents became protected; scan again")
        }
        if result.failed > 0 {
            return .failed("Removed \(result.succeeded), failed \(result.failed) Launch Agent(s)")
        }
        return .applied("Removed \(result.succeeded) broken Launch Agent(s)")
    }

    /// Checks whether a launch agent plist points at a missing binary.
    ///
    /// Only an *absolute* path that doesn't exist counts. launchd resolves a
    /// bare name ("sh", "open") through PATH, and a binary on an external or
    /// network volume is merely unavailable right now, not broken — neither
    /// is evidence the agent is dead. `com.apple.*` agents are never judged.
    func isLaunchAgentBroken(_ plist: URL) -> Bool {
        if plist.lastPathComponent.hasPrefix("com.apple.") {
            return false
        }
        let dict: [String: Any]
        do {
            let data = try Data(contentsOf: plist)
            guard let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                inspectionError = "Couldn’t inspect the launch agent at \(plist.path)"
                return false
            }
            dict = parsed
        } catch { inspectionError = "Couldn’t inspect \(plist.path): \(error.localizedDescription)"; return false }
        if let label = dict["Label"] as? String, label.hasPrefix("com.apple.") {
            return false
        }
        let executable = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        guard let executable, executable.hasPrefix("/"), !executable.hasPrefix("/Volumes/") else { return false }
        return !FileManager.default.fileExists(atPath: executable)
    }

    // MARK: - Diagnostic: network_privacy

    private func runNetworkPrivacyAudit() -> MaintenanceOutcome {
        do {
            let report = try NetworkPrivacyAuditor.inspect(
                installedApplications: NetworkPrivacyAuditor.discoverInstalledApplications()
            )
            networkPrivacyReport = report
            return networkPrivacyOutcome(for: report)
        } catch {
            return .unavailable("Local Network privacy store could not be inspected: \(error.localizedDescription)")
        }
    }

    public func networkPrivacyOutcome(for report: NetworkPrivacyAuditor.Report) -> MaintenanceOutcome {
        if report.issueCount > 0 {
            return .attention(report.summary)
        }
        if report.informationalCount > 0 {
            return .information(report.summary)
        }
        return .unchanged(report.summary)
    }

    // MARK: - Staleness gating (for tasks with no real "would this change anything" check)

    /// Days since the last successful, real (non-dry-run) run of `taskID`,
    /// or `nil` if it has never succeeded. Reads the same operation log every
    /// other task's "last run" UI already relies on, so no new state.
    private func daysSinceLastSuccess(taskID: String) -> Double? {
        if lastSuccessCache == nil {
            var cache: [String: Date] = [:]
            // Newest first, so the first hit per action is the latest run.
            for entry in opLog.recent(limit: 10000)
                where entry.outcome == .success && !entry.dryRun && cache[entry.action] == nil
            {
                cache[entry.action] = entry.timestamp
            }
            lastSuccessCache = cache
        }
        guard let timestamp = lastSuccessCache?["optimize.\(taskID)"] else { return nil }
        return max(0, Date().timeIntervalSince(timestamp) / 86400)
    }

    private func daysDescription(_ days: Double) -> String {
        let whole = Int(days)
        if whole < 1 {
            return "today"
        }
        return "\(whole) day\(whole == 1 ? "" : "s")"
    }

    // MARK: - OperationLog integration

    private func logResult(taskID: String, result: Result, dryRun: Bool) {
        let action = "optimize.\(taskID)"
        let (outcome, sizeBytes) = mapOutcome(result.outcome, dryRun: dryRun)
        opLog.append(.init(
            action: action,
            path: "",
            sizeBytes: sizeBytes,
            mode: .trash,
            outcome: outcome,
            dryRun: dryRun,
            detail: result.outcome.detail
        ))
    }

    private func mapOutcome(_ outcome: MaintenanceOutcome, dryRun: Bool) -> (OperationLog.Outcome, Int64) {
        switch outcome {
        case .recommended: (.dryRun, 0)
        case .applied: (dryRun ? .dryRun : .success, 0)
        case .unchanged: (.skipped, 0)
        case .information: (.skipped, 0)
        case .skipped: (.skipped, 0)
        case .unavailable: (.skipped, 0)
        case .attention: (.skipped, 0)
        case .failed: (.failed, 0)
        }
    }
}
