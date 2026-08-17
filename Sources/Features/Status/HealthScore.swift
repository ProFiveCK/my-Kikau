import Foundation

/// Calculates a 0-100 system health score from metrics.
/// Ported directly from Mole's `cmd/status/metrics_health.go` formula.
public enum HealthScore {
    // Weights
    private static let cpuWeight = 30.0
    private static let memWeight = 25.0
    private static let diskWeight = 20.0
    private static let thermalWeight = 15.0
    private static let ioWeight = 10.0

    // Thresholds
    private static let cpuNormal = 50.0
    private static let cpuHigh = 85.0
    private static let memNormal = 70.0
    private static let memHigh = 88.0
    private static let memPressureWarnPenalty = 5.0
    private static let memPressureCritPenalty = 15.0
    private static let diskWarn = 80.0
    private static let diskCrit = 93.0
    // `cpuTemp` now comes from real Apple Silicon SoC die sensors
    // (CPUTemperatureMonitor) rather than staying permanently 0, and Apple
    // Silicon runs comfortably much hotter under normal load than an Intel
    // chip before anything is actually wrong — 60-80°C is routine, and
    // sustained thermal throttling generally doesn't start until the
    // upper-90s/100°C. These thresholds are calibrated for that, not for
    // Intel's much lower danger zone (which this signal doesn't populate on
    // anyway — Intel Macs never expose the die sensors this reads).
    private static let thermalNormal = 85.0
    private static let thermalHigh = 100.0
    private static let ioNormal = 50.0
    private static let ioHigh = 150.0

    // Battery
    private static let batteryCycleWarn = 800
    private static let batteryCycleDanger = 900
    private static let batteryCapWarn = 80
    private static let batteryCapDanger = 60

    // Uptime
    private static let uptimeWarnSecs: UInt64 = 7 * 86400
    private static let uptimeDangerSecs: UInt64 = 14 * 86400

    // Display bands
    private static let scoreExcellent = 85
    private static let scoreGood = 65
    private static let scoreFair = 45

    public static func calculate(snapshot: MetricsSnapshot) -> (score: Int, message: String) {
        var score = 100.0
        var issues: [String] = []

        // CPU penalty
        if snapshot.cpu.usage > cpuNormal {
            if snapshot.cpu.usage > cpuHigh {
                score -= cpuWeight * (snapshot.cpu.usage - cpuNormal) / (100 - cpuNormal)
            } else {
                score -= (cpuWeight / 2) * (snapshot.cpu.usage - cpuNormal) / (cpuHigh - cpuNormal)
            }
        }
        if snapshot.cpu.usage > cpuHigh { issues.append("High CPU") }

        // Memory penalty
        if snapshot.memory.usedPercent > memNormal {
            if snapshot.memory.usedPercent > memHigh {
                score -= memWeight * (snapshot.memory.usedPercent - memNormal) / (100 - memNormal)
            } else {
                score -= (memWeight / 2) * (snapshot.memory.usedPercent - memNormal) / (memHigh - memNormal)
            }
        }
        if snapshot.memory.usedPercent > memHigh { issues.append("High Memory") }

        // Memory pressure penalty
        switch snapshot.memory.pressure {
        case "warn":
            score -= memPressureWarnPenalty
            issues.append("Memory Pressure")
        case "critical":
            score -= memPressureCritPenalty
            issues.append("Critical Memory")
        default: break
        }

        // Disk penalty
        if let disk = snapshot.disks.first {
            if disk.usedPercent > diskWarn {
                if disk.usedPercent > diskCrit {
                    score -= diskWeight * (disk.usedPercent - diskWarn) / (100 - diskWarn)
                } else {
                    score -= (diskWeight / 2) * (disk.usedPercent - diskWarn) / (diskCrit - diskWarn)
                }
            }
            if disk.usedPercent > diskCrit { issues.append("Disk Almost Full") }
        }

        // Thermal penalty
        if snapshot.thermal.cpuTemp > 0 {
            if snapshot.thermal.cpuTemp > thermalNormal {
                if snapshot.thermal.cpuTemp > thermalHigh {
                    score -= thermalWeight
                    issues.append("Overheating")
                } else {
                    score -= thermalWeight * (snapshot.thermal.cpuTemp - thermalNormal) / (thermalHigh - thermalNormal)
                }
            }
        }

        // Disk IO penalty
        let totalIO = snapshot.diskIO.readRate + snapshot.diskIO.writeRate
        if totalIO > ioNormal {
            if totalIO > ioHigh {
                score -= ioWeight
                issues.append("Heavy Disk IO")
            } else {
                score -= ioWeight * (totalIO - ioNormal) / (ioHigh - ioNormal)
            }
        }

        // Battery penalty
        if let battery = snapshot.batteries.first {
            switch batteryHealth(cycles: battery.cycleCount, capacity: battery.capacity) {
            case .danger:
                score -= 5
                issues.append("Battery Service Soon")
            case .warn:
                score -= 2
            case .ok: break
            }
        }

        // Uptime penalty
        if snapshot.uptimeSeconds > uptimeDangerSecs {
            score -= 3
            issues.append("Restart Recommended")
        } else if snapshot.uptimeSeconds > uptimeWarnSecs {
            score -= 1
        }

        // Clamp
        score = max(0, min(100, score))

        var msg: String
        switch Int(score) {
        case scoreExcellent...: msg = "Excellent"
        case scoreGood..<scoreExcellent: msg = "Good"
        case scoreFair..<scoreGood: msg = "Fair"
        default: msg = "Needs Attention"
        }
        if !issues.isEmpty {
            msg += ": " + issues.joined(separator: ", ")
        }

        return (Int(score), msg)
    }

    public enum BatteryHealth { case ok, warn, danger }

    public static func batteryHealth(cycles: Int, capacity: Int) -> BatteryHealth {
        if cycles > batteryCycleDanger || (capacity > 0 && capacity < batteryCapDanger) {
            return .danger
        }
        if cycles > batteryCycleWarn || (capacity > 0 && capacity < batteryCapWarn) {
            return .warn
        }
        return .ok
    }

    public static func formatUptime(_ seconds: UInt64) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}