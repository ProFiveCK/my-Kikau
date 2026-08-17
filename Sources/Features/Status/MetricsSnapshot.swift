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
    public var network: [NetworkStatus]
    public var gpu: [GPUStatus]
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
        network: [NetworkStatus] = [],
        gpu: [GPUStatus] = [],
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
        self.network = network
        self.gpu = gpu
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
    public var cpuTemp: Double       // Celsius, from real Apple Silicon die sensors; 0 = unavailable (e.g. Intel)
    public var batteryTemp: Double  // Battery temperature in Celsius
    public var fanSpeed: Int         // RPM
    public var fanCount: Int
    public var systemPower: Double   // System power consumption in Watts
    public var adapterPower: Double  // AC adapter max power in Watts
    public var batteryPower: Double  // Battery charge/discharge power in Watts (positive = discharging)

    public init(
        cpuTemp: Double = 0,
        batteryTemp: Double = 0,
        fanSpeed: Int = 0,
        fanCount: Int = 0,
        systemPower: Double = 0,
        adapterPower: Double = 0,
        batteryPower: Double = 0
    ) {
        self.cpuTemp = cpuTemp
        self.batteryTemp = batteryTemp
        self.fanSpeed = fanSpeed
        self.fanCount = fanCount
        self.systemPower = systemPower
        self.adapterPower = adapterPower
        self.batteryPower = batteryPower
    }
}

/// Per-interface network throughput. Mirrors Mole's `NetworkStatus`.
public struct NetworkStatus: Codable, Hashable {
    public var name: String
    public var rxRateMBs: Double
    public var txRateMBs: Double
    public var ip: String

    public init(name: String = "", rxRateMBs: Double = 0, txRateMBs: Double = 0, ip: String = "") {
        self.name = name
        self.rxRateMBs = rxRateMBs
        self.txRateMBs = txRateMBs
        self.ip = ip
    }
}

/// GPU status. Mirrors Mole's `GPUStatus`.
public struct GPUStatus: Codable, Hashable {
    public var name: String
    public var usage: Double        // Percent; -1 means unavailable
    public var memoryUsed: Double
    public var memoryTotal: Double
    public var coreCount: Int
    public var note: String

    public init(
        name: String = "",
        usage: Double = 0,
        memoryUsed: Double = 0,
        memoryTotal: Double = 0,
        coreCount: Int = 0,
        note: String = ""
    ) {
        self.name = name
        self.usage = usage
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.coreCount = coreCount
        self.note = note
    }
}
