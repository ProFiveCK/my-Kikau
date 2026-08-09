import Testing
import Core
import Features

@Suite("HealthScore")
struct HealthScoreTests {
    @Test("Perfect score when all metrics low")
    func perfectScore() {
        let snapshot = MetricsSnapshot(
            cpu: CPUStatus(usage: 10),
            memory: MemoryStatus(usedPercent: 30, pressure: "normal"),
            disks: [DiskStatus(mount: "/", usedPercent: 40)],
            diskIO: DiskIOStatus(readRate: 5, writeRate: 5),
            thermal: ThermalStatus(cpuTemp: 40)
        )
        let (score, msg) = HealthScore.calculate(snapshot: snapshot)
        #expect(score == 100)
        #expect(msg == "Excellent")
    }

    @Test("High CPU reduces score")
    func highCPU() {
        let snapshot = MetricsSnapshot(
            cpu: CPUStatus(usage: 90),
            memory: MemoryStatus(usedPercent: 30, pressure: "normal"),
            disks: [DiskStatus(mount: "/", usedPercent: 40)],
            diskIO: DiskIOStatus(),
            thermal: ThermalStatus(cpuTemp: 40)
        )
        let (score, msg) = HealthScore.calculate(snapshot: snapshot)
        #expect(score < 100)
        #expect(msg.contains("High CPU"))
    }

    @Test("Critical memory pressure adds penalty")
    func criticalMemory() {
        let snapshot = MetricsSnapshot(
            cpu: CPUStatus(usage: 10),
            memory: MemoryStatus(usedPercent: 95, pressure: "critical"),
            disks: [DiskStatus(mount: "/", usedPercent: 40)],
            diskIO: DiskIOStatus(),
            thermal: ThermalStatus(cpuTemp: 40)
        )
        let (score, msg) = HealthScore.calculate(snapshot: snapshot)
        #expect(msg.contains("Critical Memory"))
    }

    @Test("Disk almost full flagged")
    func diskFull() {
        let snapshot = MetricsSnapshot(
            cpu: CPUStatus(usage: 10),
            memory: MemoryStatus(usedPercent: 30, pressure: "normal"),
            disks: [DiskStatus(mount: "/", usedPercent: 95)],
            diskIO: DiskIOStatus(),
            thermal: ThermalStatus(cpuTemp: 40)
        )
        let (score, msg) = HealthScore.calculate(snapshot: snapshot)
        #expect(msg.contains("Disk Almost Full"))
    }

    @Test("Battery health danger")
    func batteryDanger() {
        #expect(HealthScore.batteryHealth(cycles: 950, capacity: 100) == .danger)
        #expect(HealthScore.batteryHealth(cycles: 100, capacity: 50) == .danger)
        #expect(HealthScore.batteryHealth(cycles: 850, capacity: 100) == .warn)
        #expect(HealthScore.batteryHealth(cycles: 100, capacity: 100) == .ok)
    }

    @Test("Uptime formatting")
    func uptimeFormat() {
        #expect(HealthScore.formatUptime(0) == "0m")
        #expect(HealthScore.formatUptime(3600) == "1h 0m")
        #expect(HealthScore.formatUptime(90000) == "1d 1h")
    }
}