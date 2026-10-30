import Foundation
import Core

/// A plain-text snapshot of the app's state for a support request.
///
/// Contains configuration and counts only — no file names, no paths from the
/// user's disk and no log contents — so it's safe to attach to an email.
public enum DiagnosticsReport {
    public static func generate(appVersion: String, build: String) -> String {
        let policy = ManagedPolicy.shared
        let log = OperationLog.shared
        let totals = log.totals()
        let chain = log.verifyChain()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let deniedFolders = ProtectedFolderAccessCheck.deniedFolders()

        var lines: [String] = []
        func section(_ title: String) {
            lines.append("")
            lines.append("== \(title) ==")
        }
        func row(_ key: String, _ value: String) {
            lines.append("\(key): \(value)")
        }

        lines.append("myKikau diagnostics")
        row("Generated", ISO8601DateFormatter().string(from: Date()))

        section("App")
        row("Version", "\(appVersion) (\(build))")
        row("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        row("Hardware", hardwareModel())
        row("Processors", "\(ProcessInfo.processInfo.activeProcessorCount)")
        row("Memory", ByteSizeFormatter.format(Int64(ProcessInfo.processInfo.physicalMemory)))
        row("Administrator account", isAdministrator() ? "yes" : "no")
        row("Launch at login", LaunchAtLoginService.isEnabled ? "on" : "off")

        section("Access")
        row("Full Disk Access", FullDiskAccessCheck.probe() ? "granted" : "not granted")
        row("Folders macOS is blocking", deniedFolders.isEmpty ? "none" : deniedFolders.joined(separator: ", "))

        section("Storage")
        if let volume = DiskScanner.startupVolumeInfo() {
            row("Startup disk", "\(ByteSizeFormatter.format(volume.freeBytes)) free of \(ByteSizeFormatter.format(volume.totalBytes))")
        }

        section("Settings")
        row("Operation log", log.enabled ? "on" : "off")
        row("Operation log file", log.fileURL.path)
        row("User exclusions", "\(ExclusionStore.shared.userPaths.count)")
        row("Developer tools", AppDefaults.store.bool(forKey: AppStorageKey.developerToolsEnabled) ? "on" : "off")
        row("Background scan (hours)", "\(AppDefaults.store.integer(forKey: AppStorageKey.scheduledScanIntervalHours))")

        section("Administrator policy")
        row("Managed", policy.isManaged ? "yes" : "no")
        if policy.isManaged {
            row("Disabled features", policy.disabledFeatures.sorted().joined(separator: ", "))
            row("Protected paths", "\(policy.protectedPaths.count)")
            row("Protected bundle prefixes", "\(policy.protectedBundlePrefixes.count)")
            row("Force operation log", policy.forceOperationLog ? "yes" : "no")
            row("Automatic updates disabled", policy.disableAutomaticUpdates ? "yes" : "no")
            row("Privileged tools disabled", policy.disablePrivilegedTools ? "yes" : "no")
            row("Network lookups disabled", policy.disableNetworkLookups ? "yes" : "no")
            row("Scheduled scan (hours)", policy.scheduledScanIntervalHours.map(String.init) ?? "not set")
            row("Launch at login", policy.launchAtLogin.map { $0 ? "forced on" : "forced off" } ?? "not set")
            row("Organisation", policy.organisationName ?? "not set")
            row("Support contact", policy.supportContact ?? "not set")
        }

        section("Operation log")
        row("Operations recorded", "\(totals.operations)")
        row("Moved to Trash", ByteSizeFormatter.format(totals.trashedBytes))
        row("Permanently removed", ByteSizeFormatter.format(totals.freedBytes))
        row(
            "Integrity",
            chain.isIntact
                ? "intact (\(chain.verified) verified, \(chain.unchained) unchained)"
                : (chain.firstBrokenLine.map { "BROKEN at entry \($0)" } ?? "entries missing from the start or end")
        )
        let recent = log.recent(limit: 500)
        let byOutcome = Dictionary(grouping: recent, by: \.outcome).mapValues(\.count)
        row(
            "Last 500 entries",
            OperationLog.Outcome.allCases
                .map { "\($0.rawValue) \(byOutcome[$0] ?? 0)" }
                .joined(separator: ", ")
        )

        return lines.joined(separator: "\n") + "\n"
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// Member of the `admin` group (gid 80).
    private static func isAdministrator() -> Bool {
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        return count > 0 && groups.prefix(Int(count)).contains(80)
    }
}
