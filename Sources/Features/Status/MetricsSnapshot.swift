import Foundation

/// A snapshot of system metrics at a point in time.
/// Mirrors Mole's `MetricsSnapshot` struct in `cmd/status/metrics.go`.
public struct MetricsSnapshot: Codable, Hashable {
    public let collectedAt: Date
    public let host: String
    public let uptimeSeconds: UInt64
    public let hardware: HardwareInfo
    public var healthScore: Int
    public var healthScoreMsg: String

    public var cpu: CPUStatus
    public var memory: MemoryStatus
    public var disks: [DiskStatus]
    public var diskIO: DiskIOStatus
    public var batteries: [BatteryStatus]
    public var thermal: ThermalStatus

    public init(
        collectedAt: Date = Date(),
        host: String = "",
        uptimeSeconds: UInt64 = 0,
        hardware: HardwareInfo = HardwareInfo(),
        healthScore: Int = 100,
        healthScoreMsg: String = "Excellent",
        cpu: CPUStatus = CPUStatus(),
        memory: MemoryStatus = MemoryStatus(),
        disks: [DiskStatus] = [],
        diskIO: DiskIOStatus = DiskIOStatus(),
        batteries: [BatteryStatus] = [],
        thermal: ThermalStatus = ThermalStatus()
    ) {
        self.collectedAt = collectedAt
        self.host = host
        self.uptimeSeconds = uptimeSeconds
        self.hardware = hardware
        self.healthScore = healthScore
        self.healthScoreMsg = healthScoreMsg
        self.cpu = cpu
        self.memory = memory
        self.disks = disks
        self.diskIO = diskIO
        self.batteries = batteries
        self.thermal = thermal
    }
}

public struct HardwareInfo: Codable, Hashable {
    public var model: String
    public var cpuModel: String
    public var totalRAM: String
    public var osVersion: String

    public init(model: String = "", cpuModel: String = "", totalRAM: String = "", osVersion: String = "") {
        self.model = model
        self.cpuModel = cpuModel
        self.totalRAM = totalRAM
        self.osVersion = osVersion
    }
}

public struct CPUStatus: Codable, Hashable {
    public var usage: Double
    public var perCore: [Double]
    public var coreCount: Int
    public var logicalCPU: Int

    public init(usage: Double = 0, perCore: [Double] = [], coreCount: Int = 0, logicalCPU: Int = 0) {
        self.usage = usage
        self.perCore = perCore
        self.coreCount = coreCount
        self.logicalCPU = logicalCPU
    }
}

public struct MemoryStatus: Codable, Hashable {
    public var used: UInt64
    public var total: UInt64
    public var available: UInt64
    public var usedPercent: Double
    public var pressure: String  // "normal", "warn", "critical"

    public init(used: UInt64 = 0, total: UInt64 = 0, available: UInt64 = 0, usedPercent: Double = 0, pressure: String = "normal") {
        self.used = used
        self.total = total
        self.available = available
        self.usedPercent = usedPercent
        self.pressure = pressure
    }
}

public struct DiskStatus: Codable, Hashable {
    public var mount: String
    public var used: UInt64
    public var total: UInt64
    public var usedPercent: Double

    public init(mount: String = "/", used: UInt64 = 0, total: UInt64 = 0, usedPercent: Double = 0) {
        self.mount = mount
        self.used = used
        self.total = total
        self.usedPercent = usedPercent
    }
}

public struct DiskIOStatus: Codable, Hashable {
    public var readRate: Double   // MB/s
    public var writeRate: Double  // MB/s

    public init(readRate: Double = 0, writeRate: Double = 0) {
        self.readRate = readRate
        self.writeRate = writeRate
    }
}

public struct BatteryStatus: Codable, Hashable {
    public var percent: Double
    public var status: String     // "Charging", "Charged", "Discharging"
    public var cycleCount: Int
    public var capacity: Int      // Max capacity percentage (e.g. 85 = 85%)

    public init(percent: Double = 0, status: String = "", cycleCount: Int = 0, capacity: Int = 0) {
        self.percent = percent
        self.status = status
        self.cycleCount = cycleCount
        self.capacity = capacity
    }
}

public struct ThermalStatus: Codable, Hashable {
    public var cpuTemp: Double    // Celsius
    public var fanSpeed: Int      // RPM

    public init(cpuTemp: Double = 0, fanSpeed: Int = 0) {
        self.cpuTemp = cpuTemp
        self.fanSpeed = fanSpeed
    }
}