import Foundation
import Darwin
import IOKit
import IOKit.ps

/// Collects system metrics concurrently using TaskGroup.
/// Mirrors Mole's `cmd/status/metrics.go` Collector with fan-out collection.
public final class MetricsCollector {
    public static let shared = MetricsCollector()

    private var prevCPUTotal: UInt64 = 0
    private var prevCPUIdle: UInt64 = 0
    private var lastCPUAt: Date = .distantPast

    public init() {}

    /// Collects a full metrics snapshot.
    public func collect() async -> MetricsSnapshot {
        async let cpu = collectCPU()
        async let memory = collectMemory()
        async let disks = collectDisks()
        async let batteries = collectBatteries()
        async let uptime = collectUptime()
        async let host = collectHost()

        let snapshot = MetricsSnapshot(
            host: await host,
            uptimeSeconds: await uptime,
            cpu: await cpu,
            memory: await memory,
            disks: await disks,
            batteries: await batteries
        )

        var withScore = snapshot
        let (score, msg) = HealthScore.calculate(snapshot: withScore)
        withScore.healthScore = score
        withScore.healthScoreMsg = msg
        return withScore
    }

    // MARK: - CPU

    private func collectCPU() async -> CPUStatus {
        var cpuInfo: host_cpu_load_info?
        var count = UInt32(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebPtr, &count)
            }
        }

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return CPUStatus(usage: 0, coreCount: ProcessInfo.processInfo.activeProcessorCount)
        }

        let total = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.2) + UInt64(info.cpu_ticks.3)
        let idle = UInt64(info.cpu_ticks.2)

        var usage: Double = 0
        let now = Date()
        if lastCPUAt != .distantPast && now.timeIntervalSince(lastCPUAt) < 60 {
            let deltaTotal = total - prevCPUTotal
            let deltaIdle = idle - prevCPUIdle
            if deltaTotal > 0 {
                usage = (1.0 - Double(deltaIdle) / Double(deltaTotal)) * 100
            }
        }
        prevCPUTotal = total
        prevCPUIdle = idle
        lastCPUAt = now

        let logical = ProcessInfo.processInfo.activeProcessorCount
        return CPUStatus(usage: usage, coreCount: logical, logicalCPU: logical)
    }

    // MARK: - Memory

    private func collectMemory() async -> MemoryStatus {
        var stats = vm_statistics()
        var count = mach_msg_type_size_t(MemoryLayout<vm_statistics>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebPtr in
                host_statistics(mach_host_self(), HOST_VM_INFO, rebPtr, &count)
            }
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let totalMemory = UInt64(ProcessInfo.processInfo.physicalMemory)

        guard result == KERN_SUCCESS else {
            return MemoryStatus(total: totalMemory)
        }

        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let used = active + wired
        let available = free + inactive
        let usedPercent = totalMemory > 0 ? Double(used) / Double(totalMemory) * 100 : 0

        // Pressure level via host_statistics64 (HOST_VM_INFO64 flavor)
        // On macOS the memory pressure is inferred from the free/inactive ratio.
        let pressure: String
        if totalMemory > 0 {
            let freePercent = Double(free + inactive) / Double(totalMemory) * 100
            if freePercent < 10 { pressure = "critical" }
            else if freePercent < 20 { pressure = "warn" }
            else { pressure = "normal" }
        } else {
            pressure = "normal"
        }

        return MemoryStatus(used: used, total: totalMemory, available: available, usedPercent: usedPercent, pressure: pressure)
    }

    // MARK: - Disk

    private func collectDisks() async -> [DiskStatus] {
        var results: [DiskStatus] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Home volume (root)
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            let total = (attrs[.systemSize] as? UInt64) ?? 0
            let free = (attrs[.systemFreeSize] as? UInt64) ?? 0
            let used = total - free
            let percent = total > 0 ? Double(used) / Double(total) * 100 : 0
            results.append(DiskStatus(mount: "/", used: used, total: total, usedPercent: percent))
        }

        _ = home // suppress unused warning
        return results
    }

    // MARK: - Battery

    private func collectBatteries() async -> [BatteryStatus] {
        var batteries: [BatteryStatus] = []

        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let percent = (desc[kIOPSCurrentCapacityKey] as? Double) ?? 0
            let maxCap = (desc[kIOPSMaxCapacityKey] as? Double) ?? 100
            let pct = maxCap > 0 ? percent / maxCap * 100 : 0
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let status = isCharging ? "Charging" : "Discharging"

            batteries.append(BatteryStatus(
                percent: pct,
                status: status,
                cycleCount: 0,
                capacity: 100
            ))
        }
        return batteries
    }

    // MARK: - Uptime

    private func collectUptime() async -> UInt64 {
        var bootTime = timeval()
        var size = Int(MemoryLayout<timeval>.size)
        let name = "kern.boottime"
        withUnsafeMutablePointer(to: &bootTime) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: size) { rebPtr in
                sysctlbyname(name, rebPtr, &size, nil, 0)
            }
        }
        return UInt64(max(0, Date().timeIntervalSince1970 - Double(bootTime.tv_sec)))
    }

    // MARK: - Host

    private func collectHost() async -> String {
        ProcessInfo.processInfo.hostName
    }
}