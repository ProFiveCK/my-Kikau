import Foundation
import Core
import Features

// mykikau-cli — a read-only companion to the myKikau app, for scripts and
// fleet tooling (an MDM extension attribute, a scheduled report).
//
// It measures and reports. It never removes anything: every deletion in
// myKikau goes through a plan a person reviews, and there is no one to review
// a plan here.
//
// It reads the app's preference domain, so exclusions and administrator
// policy apply exactly as they do in the app.

AppDefaults.store = UserDefaults(suiteName: AppDefaults.appDomain) ?? .standard

/// Kept in step with Info.plist by scripts/bump-version.sh.
let cliVersion = "0.10.6"

let usage = """
Usage: mykikau-cli <command> [options]

Commands:
  scan [--json]            Measure what Clean could reclaim, per category.
  status [--json]          Current CPU, memory, disk, battery and health score.
  policy [--json]          The administrator policy in effect on this Mac.
  log verify               Check the operation log's integrity chain.
  log export <path> [--csv]
                           Write the operation log to a file (JSON Lines by default).
  version                  Print the version.

Nothing is ever removed by this tool.
"""

func emit(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        fail("Could not encode output.")
    }
    print(text)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

struct ScanSection: Encodable {
    let id: String
    let name: String
    let items: Int
    let protectedItems: Int
    let bytes: Int64
}

struct ScanReport: Encodable {
    let generatedAt: Date
    let host: String
    let totalBytes: Int64
    let totalItems: Int
    let fullDiskAccess: Bool
    let sections: [ScanSection]
}

struct PolicyReport: Encodable {
    let managed: Bool
    let disabledFeatures: [String]
    let protectedPaths: [String]
    let protectedBundlePrefixes: [String]
    let forceOperationLog: Bool
    let disableAutomaticUpdates: Bool
    let disablePrivilegedTools: Bool
    let scheduledScanIntervalHours: Int?
}

func runScan(json: Bool) {
    let policy = ManagedPolicy.shared
    if policy.isFeatureDisabled("clean") {
        fail("Clean is disabled by your organisation.", code: 3)
    }
    let plans = CleanScanner.scanAll()
    let sections = CleanScanner.Section.allCases.map { section -> ScanSection in
        let plan = plans[section] ?? .empty
        return ScanSection(
            id: section.rawValue, name: section.displayName,
            items: plan.items.count, protectedItems: plan.protectedItems.count,
            bytes: plan.totalReclaimable
        )
    }
    let report = ScanReport(
        generatedAt: Date(),
        host: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        totalBytes: sections.reduce(0) { $0 + $1.bytes },
        totalItems: sections.reduce(0) { $0 + $1.items },
        fullDiskAccess: FullDiskAccessCheck.probe(),
        sections: sections
    )
    if json {
        emit(report)
        return
    }
    print("Reclaimable: \(ByteSizeFormatter.format(report.totalBytes)) in \(report.totalItems) items")
    for section in sections where section.items > 0 {
        let name = section.name.padding(toLength: 26, withPad: " ", startingAt: 0)
        print("  \(name) \(ByteSizeFormatter.format(section.bytes))  (\(section.items) items)")
    }
    if !report.fullDiskAccess {
        print("Note: this terminal doesn't have Full Disk Access, so some locations were not readable.")
    }
}

func runStatus(json: Bool) async {
    let collector = MetricsCollector()
    // CPU, network and disk-IO figures are rates: they need two samples.
    _ = await collector.collect()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let snapshot = await collector.collect()
    if json {
        emit(snapshot)
        return
    }
    print("Health: \(snapshot.healthScore)/100 — \(snapshot.healthScoreMsg)")
    print("CPU: \(Int(snapshot.cpu.usage))%")
    print("Memory: \(Int(snapshot.memory.usedPercent))% used, pressure \(snapshot.memory.pressure)")
    if let disk = snapshot.disks.first {
        print("Disk: \(ByteSizeFormatter.format(Int64(disk.total - disk.used))) free of \(ByteSizeFormatter.format(Int64(disk.total)))")
    }
    if let battery = snapshot.batteries.first {
        var line = "Battery: \(Int(battery.percent))% \(battery.status)"
        if battery.capacity > 0 {
            line += ", health \(battery.capacity)%"
        }
        if battery.cycleCount > 0 {
            line += ", \(battery.cycleCount) cycles"
        }
        print(line)
    }
}

func runPolicy(json: Bool) {
    let policy = ManagedPolicy.shared
    let report = PolicyReport(
        managed: policy.isManaged,
        disabledFeatures: policy.disabledFeatures.sorted(),
        protectedPaths: policy.protectedPaths,
        protectedBundlePrefixes: policy.protectedBundlePrefixes,
        forceOperationLog: policy.forceOperationLog,
        disableAutomaticUpdates: policy.disableAutomaticUpdates,
        disablePrivilegedTools: policy.disablePrivilegedTools,
        scheduledScanIntervalHours: policy.scheduledScanIntervalHours
    )
    if json {
        emit(report)
        return
    }
    guard report.managed else {
        print("No administrator policy is in effect.")
        return
    }
    print("Administrator policy in effect:")
    if !report.disabledFeatures.isEmpty {
        print("  Disabled features: \(report.disabledFeatures.joined(separator: ", "))")
    }
    if !report.protectedPaths.isEmpty {
        print("  Protected paths: \(report.protectedPaths.joined(separator: ", "))")
    }
    if !report.protectedBundlePrefixes.isEmpty {
        print("  Protected software: \(report.protectedBundlePrefixes.joined(separator: ", "))")
    }
    if report.forceOperationLog {
        print("  Operation log: always on")
    }
    if report.disableAutomaticUpdates {
        print("  Automatic updates: off")
    }
    if report.disablePrivilegedTools {
        print("  Administrator actions: disabled")
    }
    if let hours = report.scheduledScanIntervalHours {
        print("  Background scan: every \(hours) hours")
    }
}

func runLog(_ arguments: [String]) {
    guard let subcommand = arguments.first else { fail(usage, code: 2) }
    switch subcommand {
    case "verify":
        let status = OperationLog.shared.verifyChain()
        if let line = status.firstBrokenLine {
            fail("BROKEN at entry \(line): the log was edited or an entry was removed.", code: 4)
        }
        if status.truncated {
            fail("BROKEN: entries are missing from the start or the end of the log.", code: 4)
        }
        print("OK — \(status.verified) entries verified, \(status.unchained) not chained.")
    case "export":
        guard arguments.count >= 2 else { fail("log export needs a destination path.", code: 2) }
        let destination = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
        do {
            try OperationLog.shared.export(to: destination, format: arguments.contains("--csv") ? .csv : .jsonl)
            print("Wrote \(destination.path)")
        } catch {
            fail("Export failed: \(error.localizedDescription)")
        }
    default:
        fail(usage, code: 2)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")

switch arguments.first {
case "scan":
    runScan(json: json)
case "status":
    await runStatus(json: json)
case "policy":
    runPolicy(json: json)
case "log":
    runLog(Array(arguments.dropFirst()))
case "version", "--version":
    print("mykikau-cli \(cliVersion)")
case "help", "--help", "-h", nil:
    print(usage)
default:
    fail(usage, code: 2)
}
