import Foundation
import Darwin
import IOKit
import IOKit.ps

/// Collects system metrics concurrently using TaskGroup.
public final class MetricsCollector {
    public static let shared = MetricsCollector()

    /// Previous user/system/idle/nice tick counters.
    private var prevCPUTicks: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    private var lastCPUAt: Date = .distantPast

    // Network rate collection state (per-instance to diff successive samples).
    private let networkBox = NetworkSampleBox()
    // Thermal fan-source cache.
    private let thermalBox = ThermalSampleBox()
    // GPU static info + usage cache.
    private let gpuBox = GPUSampleBox()
    // Disk IO rate collection state.
    private let diskIOBox = DiskIOSampleBox()
    // CPU die temperature sensor cache (Apple Silicon only).
    private let cpuTempBox = CPUTempSampleBox()

    public init() {}

    /// Collects a full metrics snapshot.
    public func collect() async -> MetricsSnapshot {
        async let cpu = collectCPU()
        async let memory = collectMemory()
        async let disks = collectDisks()
        async let batteries = collectBatteries()
        async let uptime = collectUptime()
        async let host = collectHost()
        async let network = collectNetwork()
        async let thermal = collectThermal()
        async let cpuTemp = collectCPUTemp()
        async let gpu = collectGPU()
        async let diskIO = collectDiskIO()

        var thermalStatus = await thermal
        thermalStatus.cpuTemp = await cpuTemp

        let snapshot = MetricsSnapshot(
            host: await host,
            uptimeSeconds: await uptime,
            cpu: await cpu,
            memory: await memory,
            disks: await disks,
            diskIO: await diskIO,
            network: await network,
            gpu: await gpu,
            batteries: await batteries,
            thermal: thermalStatus
        )

        var withScore = snapshot
        let (score, msg) = HealthScore.calculate(snapshot: withScore)
        withScore.healthScore = score
        withScore.healthScoreMsg = msg
        return withScore
    }

    // MARK: - CPU

    private func collectCPU() async -> CPUStatus {
        // NOTE: must be a plain (non-Optional) zero-initialized struct. Wrapping it in
        // `host_cpu_load_info?` and reinterpreting *that* pointer's memory as an
        // `integer_t` buffer (the previous approach) relies on Optional<T> having the
        // exact same memory layout as T, which Swift does not guarantee for a plain C
        // struct like this one — host_statistics ended up writing into the wrong
        // offsets, so `usage` silently computed as ~0 every tick instead of throwing
        // or crashing. A non-Optional struct's layout is exactly its fields, no
        // discriminator, so the raw pointer reinterpretation is well-defined.
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return CPUStatus(usage: 0, coreCount: ProcessInfo.processInfo.activeProcessorCount)
        }

        let ticks = cpuInfo.cpu_ticks
        var usage: Double = 0
        let now = Date()
        if lastCPUAt != .distantPast && now.timeIntervalSince(lastCPUAt) < 60 {
            usage = Self.cpuUsage(previous: prevCPUTicks, current: ticks)
        }
        prevCPUTicks = ticks
        lastCPUAt = now

        let logical = ProcessInfo.processInfo.activeProcessorCount
        return CPUStatus(usage: usage, coreCount: logical, logicalCPU: logical)
    }

    /// Busy share of the interval between two tick samples, 0…100.
    ///
    /// The kernel's counters are 32-bit and wrap after weeks of uptime, so
    /// each delta uses wrapping subtraction: across a wrap it still yields
    /// the true (small) difference instead of trapping.
    static func cpuUsage(
        previous: (UInt32, UInt32, UInt32, UInt32),
        current: (UInt32, UInt32, UInt32, UInt32)
    ) -> Double {
        let user = UInt64(current.0 &- previous.0)
        let system = UInt64(current.1 &- previous.1)
        let idle = UInt64(current.2 &- previous.2)
        let nice = UInt64(current.3 &- previous.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return min(100, max(0, (1.0 - Double(idle) / Double(total)) * 100))
    }

    // MARK: - Memory

    private func collectMemory() async -> MemoryStatus {
        let totalMemory = UInt64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemoryStatus(total: totalMemory)
        }
        return Self.memoryStatus(from: stats, pageSize: UInt64(vm_kernel_page_size), total: totalMemory, pressureLevel: Self.kernelPressureLevel())
    }

    /// "Memory Used" the way Activity Monitor defines it: app memory
    /// (anonymous pages that aren't purgeable) + wired + compressed. Cached
    /// files and free pages are both available, so a Mac with little *free*
    /// memory is not under pressure — macOS fills free RAM with cache by design.
    static func memoryStatus(
        from stats: vm_statistics64,
        pageSize: UInt64,
        total: UInt64,
        pressureLevel: Int32?
    ) -> MemoryStatus {
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let used = min(total, (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize)
        let available = total > used ? total - used : 0
        let usedPercent = total > 0 ? Double(used) / Double(total) * 100 : 0
        return MemoryStatus(
            used: used, total: total, available: available,
            usedPercent: usedPercent, pressure: pressureName(level: pressureLevel)
        )
    }

    /// The kernel's own memory-pressure verdict — the figure behind Activity
    /// Monitor's pressure graph — rather than a guess from page counts.
    static func kernelPressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }

    /// 1 = normal, 2 = warning, 4 = critical (`dispatch_source_memorypressure_flags_t`).
    static func pressureName(level: Int32?) -> String {
        switch level {
        case 4: "critical"
        case 2: "warn"
        default: "normal"
        }
    }

    // MARK: - Disk

    private func collectDisks() async -> [DiskStatus] {
        // "Free" is what Finder calls Available: it counts space macOS will
        // purge on demand. Analyse uses the same figure, so the two screens agree.
        let root = URL(fileURLWithPath: "/")
        guard let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]), let totalCapacity = values.volumeTotalCapacity, totalCapacity > 0 else {
            return []
        }
        let total = UInt64(totalCapacity)
        let free = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)))
        let used = total > free ? total - free : 0
        return [DiskStatus(mount: "/", used: used, total: total, usedPercent: Double(used) / Double(total) * 100)]
    }

    // MARK: - Battery

    private func collectBatteries() async -> [BatteryStatus] {
        var batteries: [BatteryStatus] = []

        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        // Wear data (cycle count, capacity vs design) isn't in the power-source
        // description; it comes from the battery's registry entry.
        let health = SmartBattery.properties().map(SmartBattery.health(from:))

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            // Only the internal battery — a UPS or a Bluetooth accessory is
            // also a "power source".
            if let type = desc[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType { continue }
            let percent = (desc[kIOPSCurrentCapacityKey] as? Double) ?? 0
            let maxCap = (desc[kIOPSMaxCapacityKey] as? Double) ?? 100
            let pct = maxCap > 0 ? percent / maxCap * 100 : 0

            batteries.append(BatteryStatus(
                percent: pct,
                status: Self.batteryStatusText(
                    isCharging: (desc[kIOPSIsChargingKey] as? Bool) ?? false,
                    isCharged: (desc[kIOPSIsChargedKey] as? Bool) ?? false,
                    onACPower: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                ),
                cycleCount: health?.cycleCount ?? 0,
                capacity: health?.capacityPercent ?? 0
            ))
        }
        return batteries
    }

    static func batteryStatusText(isCharging: Bool, isCharged: Bool, onACPower: Bool) -> String {
        if isCharging { return "Charging" }
        if isCharged { return "Charged" }
        // Plugged in but holding (optimised charging, or a full battery).
        if onACPower { return "On Power" }
        return "Discharging"
    }

    // MARK: - Uptime

    private func collectUptime() async -> UInt64 {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else { return 0 }
        return UInt64(max(0, Date().timeIntervalSince1970 - Double(bootTime.tv_sec)))
    }

    // MARK: - Host

    /// The computer name from Sharing settings. Read once: it's not a
    /// per-tick value, and `ProcessInfo.hostName` can block on a DNS lookup.
    private static let hostName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    private func collectHost() async -> String {
        Self.hostName
    }

    // MARK: - Network

    private func collectNetwork() async -> [NetworkStatus] {
        NetworkMonitor.collect(into: networkBox)
    }

    // MARK: - Thermal

    private func collectThermal() async -> ThermalStatus {
        ThermalMonitor.collect(from: thermalBox)
    }

    // MARK: - CPU Temperature

    private func collectCPUTemp() async -> Double {
        CPUTemperatureMonitor.read(from: cpuTempBox)
    }

    // MARK: - GPU

    private func collectGPU() async -> [GPUStatus] {
        GPUMonitor.collect(from: gpuBox)
    }

    // MARK: - Disk IO

    private func collectDiskIO() async -> DiskIOStatus {
        DiskIOMonitor.collect(from: diskIOBox)
    }
}
