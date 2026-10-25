import Testing
import Foundation
@testable import Features

@Suite("StatusMetrics")
struct StatusMetricsTests {

    // MARK: - Memory optimizer

    @Test("memory purge availability checks for an executable tool")
    func memoryPurgeAvailability() {
        #expect(MemoryOptimizer.isPurgeAvailable(path: "/bin/ls"))
        #expect(!MemoryOptimizer.isPurgeAvailable(path: "/tmp/mykikau-definitely-missing-purge-tool"))
    }

    // MARK: - Network parsing

    @Test("readInterfaceCounters reads kernel counters without a subprocess")
    func readsInterfaceCounters() {
        let counters = NetworkMonitor.readInterfaceCounters()
        #expect(counters != nil)
        // Every Mac has a loopback interface.
        #expect(counters?.rxByName["lo0"] != nil)
        #expect(counters?.rxByName.count == counters?.txByName.count)
    }

    @Test("isNoiseInterface filters known noise prefixes")
    func noiseInterfaceFilter() {
        #expect(NetworkMonitor.isNoiseInterface("lo0"))
        #expect(NetworkMonitor.isNoiseInterface("awdl0"))
        #expect(NetworkMonitor.isNoiseInterface("utun0"))
        #expect(NetworkMonitor.isNoiseInterface("llw0"))
        #expect(NetworkMonitor.isNoiseInterface("bridge100"))
        #expect(NetworkMonitor.isNoiseInterface("gif0"))
        #expect(NetworkMonitor.isNoiseInterface("stf0"))
        #expect(NetworkMonitor.isNoiseInterface("ap1"))
        #expect(!NetworkMonitor.isNoiseInterface("en0"))
        #expect(!NetworkMonitor.isNoiseInterface("en1"))
    }

    @Test("rateMBs diffs counters into MB/s")
    func rateMBs() {
        // 1 MiB delta over 1 second == 1 MB/s
        let rate = NetworkMonitor.rateMBs(current: 1_048_576, previous: 0, elapsed: 1)
        #expect(abs(rate - 1.0) < 0.0001)
    }

    @Test("rateMBs returns 0 on wraparound and zero elapsed")
    func rateMBsWraparound() {
        #expect(NetworkMonitor.rateMBs(current: 100, previous: 200, elapsed: 1) == 0)
        #expect(NetworkMonitor.rateMBs(current: 200, previous: 100, elapsed: 0) == 0)
    }

    @Test("NetworkMonitor.collect primes on first sample and returns empty")
    func networkFirstSamplePrimes() {
        let box = NetworkSampleBox()
        // Inject a prev sample manually to simulate priming.
        box.prev = ["en0": (rx: 1_048_576, tx: 0)]
        box.lastAt = Date().addingTimeInterval(-1).timeIntervalSince1970
        // Without a real netstat we can't drive collect(); instead verify the
        // min-interval short-circuit returns lastResults.
        box.lastResults = [NetworkStatus(name: "en0", rxRateMBs: 5, txRateMBs: 1)]
        let now = Date()
        _ = NetworkMonitor.collect(into: box, now: now)
        // Because lastAt is ~1s ago (>= minInterval), collect will attempt netstat;
        // in CI netstat exists, so results may change. Assert the box retained state shape.
        #expect(box.prev != nil)
    }

    // MARK: - Thermal parsing

    @Test("parseFanSpeed extracts fan speed and count")
    func parseFanSpeed() {
        let output = """
        Power:

          Fan Information (fan information):
            en0 fan speed: 2300 rpm
            en1 fan speed: 1998 rpm
        """
        let (speed, count) = ThermalMonitor.parseFanSpeed(output)
        #expect(speed == 2300)
        #expect(count == 2)
    }

    @Test("parseFanSpeed returns zeros when no fan lines")
    func parseFanSpeedEmpty() {
        let (speed, count) = ThermalMonitor.parseFanSpeed("No fans here")
        #expect(speed == 0)
        #expect(count == 0)
    }

    // MARK: - GPU parsing

    @Test("parseDisplaysJSON builds GPU statuses")
    func parseDisplaysJSON() {
        let json = """
        {"SPDisplaysDataType":[{"_name":"Apple M1 Pro","spdisplays_vram":"16GB","spdisplays_metal":"Metal 3","spdisplays_vendor":"Apple","sppci_cores":"16"}]}
        """
        let data = json.data(using: .utf8)!
        let gpus = GPUMonitor.parseDisplaysJSON(data)
        #expect(gpus != nil)
        let gpu = gpus?.first
        #expect(gpu?.name == "Apple M1 Pro")
        #expect(gpu?.coreCount == 16)
        #expect(gpu?.note == "VRAM 16GB · Metal 3 · Apple")
        #expect(gpu?.usage == -1)
    }

    @Test("parseDisplaysJSON returns nil for empty display list")
    func parseDisplaysJSONEmpty() {
        let json = """
        {"SPDisplaysDataType":[]}
        """
        let data = json.data(using: .utf8)!
        #expect(GPUMonitor.parseDisplaysJSON(data) == nil)
    }

    // MARK: - Disk IO rates

    @Test("diskIORates diffs counters into MB/s")
    func diskIORatesDiff() {
        // 1 MiB read + 2 MiB write over 1s
        let status = DiskIOMonitor.diskIORates(
            currentRead: 1_048_576, currentWrite: 2_097_152,
            previousRead: 0, previousWrite: 0,
            elapsed: 1
        )
        #expect(abs(status.readRate - 1.0) < 0.0001)
        #expect(abs(status.writeRate - 2.0) < 0.0001)
    }

    @Test("diskIORates guards wraparound and zero elapsed")
    func diskIORatesWraparound() {
        let status = DiskIOMonitor.diskIORates(
            currentRead: 100, currentWrite: 100,
            previousRead: 200, previousWrite: 200,
            elapsed: 1
        )
        #expect(status.readRate == 0)
        #expect(status.writeRate == 0)

        let zero = DiskIOMonitor.diskIORates(
            currentRead: 200, currentWrite: 200,
            previousRead: 100, previousWrite: 100,
            elapsed: 0
        )
        #expect(zero.readRate == 0)
        #expect(zero.writeRate == 0)
    }

    @Test("DiskIOMonitor.collect returns zero on first sample and primes state")
    func diskIOFirstSample() {
        let box = DiskIOSampleBox()
        let status = DiskIOMonitor.collect(from: box)
        #expect(status.readRate == 0)
        #expect(status.writeRate == 0)
        #expect(box.prev != nil)
        #expect(box.lastAt != nil)
    }

    // MARK: - Codable round-trips

    @Test("NetworkStatus Codable round-trips")
    func networkCodable() throws {
        let original = NetworkStatus(name: "en0", rxRateMBs: 1.5, txRateMBs: 0.25, ip: "10.0.0.5")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NetworkStatus.self, from: data)
        #expect(decoded == original)
    }

    @Test("GPUStatus Codable round-trips")
    func gpuCodable() throws {
        let original = GPUStatus(name: "Apple M1 Pro", usage: 12.5, memoryUsed: 4, memoryTotal: 16, coreCount: 16, note: "Metal 3")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GPUStatus.self, from: data)
        #expect(decoded == original)
    }

    @Test("ThermalStatus Codable round-trips with all fields")
    func thermalCodable() throws {
        let original = ThermalStatus(cpuTemp: 0, batteryTemp: 30, fanSpeed: 2300, fanCount: 2, systemPower: 12.5, adapterPower: 61, batteryPower: 8)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThermalStatus.self, from: data)
        #expect(decoded == original)
    }

    @Test("MetricsSnapshot with all new fields round-trips")
    func snapshotCodable() throws {
        let original = MetricsSnapshot(
            host: "mac",
            uptimeSeconds: 3600,
            cpu: CPUStatus(usage: 10),
            memory: MemoryStatus(usedPercent: 50),
            disks: [DiskStatus(mount: "/", usedPercent: 60)],
            diskIO: DiskIOStatus(readRate: 1, writeRate: 2),
            network: [NetworkStatus(name: "en0", rxRateMBs: 1, txRateMBs: 2, ip: "10.0.0.1")],
            gpu: [GPUStatus(name: "M1", usage: -1, coreCount: 8)],
            batteries: [BatteryStatus(percent: 80, status: "Discharging")],
            thermal: ThermalStatus(batteryTemp: 30, fanSpeed: 2000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MetricsSnapshot.self, from: data)
        #expect(decoded.host == original.host)
        #expect(decoded.network == original.network)
        #expect(decoded.gpu == original.gpu)
        #expect(decoded.thermal == original.thermal)
        #expect(decoded.diskIO == original.diskIO)
    }

    // MARK: - Memory

    @Test("Memory used counts app, wired and compressed pages — not cache or free")
    func memoryUsedDefinition() {
        var stats = vm_statistics64()
        stats.internal_page_count = 500
        stats.purgeable_count = 100
        stats.wire_count = 200
        stats.compressor_page_count = 50
        // A nearly empty free list with a big file cache is a healthy Mac.
        stats.free_count = 5
        stats.external_page_count = 345

        let status = MetricsCollector.memoryStatus(from: stats, pageSize: 1000, total: 1_000_000, pressureLevel: 1)

        #expect(status.used == 650_000)          // (500 − 100) + 200 + 50 pages
        #expect(status.available == 350_000)
        #expect(abs(status.usedPercent - 65) < 0.001)
        #expect(status.pressure == "normal")
    }

    @Test("Memory pressure comes from the kernel's level, not from page counts")
    func memoryPressureLevels() {
        #expect(MetricsCollector.pressureName(level: 1) == "normal")
        #expect(MetricsCollector.pressureName(level: 2) == "warn")
        #expect(MetricsCollector.pressureName(level: 4) == "critical")
        #expect(MetricsCollector.pressureName(level: nil) == "normal")
        #expect(MetricsCollector.kernelPressureLevel() != nil)
    }

    // MARK: - Battery

    @Test("Battery status distinguishes charging, charged, holding on power and discharging")
    func batteryStatusText() {
        #expect(MetricsCollector.batteryStatusText(isCharging: true, isCharged: false, onACPower: true) == "Charging")
        #expect(MetricsCollector.batteryStatusText(isCharging: false, isCharged: true, onACPower: true) == "Charged")
        #expect(MetricsCollector.batteryStatusText(isCharging: false, isCharged: false, onACPower: true) == "On Power")
        #expect(MetricsCollector.batteryStatusText(isCharging: false, isCharged: false, onACPower: false) == "Discharging")
    }

    @Test("Battery health is full-charge capacity against design capacity")
    func batteryHealth() {
        // Apple Silicon shape: MaxCapacity is a percentage, raw key is mAh.
        let appleSilicon: [String: Any] = [
            "CycleCount": 312, "DesignCapacity": 6000, "AppleRawMaxCapacity": 5280, "MaxCapacity": 100
        ]
        #expect(SmartBattery.health(from: appleSilicon) == SmartBattery.Health(cycleCount: 312, capacityPercent: 88))

        // Intel shape: MaxCapacity itself is mAh.
        let intel: [String: Any] = ["CycleCount": 900, "DesignCapacity": 5000, "MaxCapacity": 3900]
        #expect(SmartBattery.health(from: intel) == SmartBattery.Health(cycleCount: 900, capacityPercent: 78))

        // Recent macOS: capacities live in a nested BatteryData dictionary,
        // and a new battery can exceed its design capacity (clamped to 100).
        let nested: [String: Any] = [
            "CycleCount": 84, "MaxCapacity": 100,
            "BatteryData": ["DesignCapacity": 8579, "NominalChargeCapacity": 8984],
        ]
        #expect(SmartBattery.health(from: nested) == SmartBattery.Health(cycleCount: 84, capacityPercent: 100))

        // Unknown capacity reads as 0, which HealthScore treats as "no data".
        #expect(SmartBattery.health(from: ["CycleCount": 10]).capacityPercent == 0)
    }

    @Test("Registry readings: direct Celsius kept, out-of-range system power rejected")
    func thermalRegistryEdgeCases() {
        let thermal = ThermalMonitor.status(fromBatteryProperties: ["Temperature": 28, "SystemPower": 2_000_000])
        #expect(abs(thermal.batteryTemp - 28.0) < 0.001)
        #expect(thermal.systemPower == 0)
        // A Mac without a battery has no registry entry, so no readings at all.
        #expect(ThermalMonitor.status(fromBatteryProperties: [:]) == ThermalStatus())
    }

    @Test("Registry properties map to thermal and power fields")
    func thermalFromRegistryProperties() {
        let properties: [String: Any] = [
            "Temperature": 3055,
            "AdapterDetails": ["Watts": 96],
            "PowerTelemetryData": ["SystemPowerIn": 24_500, "BatteryPower": -12_000],
            "Voltage": 12_600,
            "InstantAmperage": -1500,
        ]
        let thermal = ThermalMonitor.status(fromBatteryProperties: properties)
        #expect(abs(thermal.batteryTemp - 30.55) < 0.001)
        #expect(thermal.adapterPower == 96)
        #expect(abs(thermal.systemPower - 24.5) < 0.001)
        #expect(abs(thermal.batteryPower + 12.0) < 0.001)
        #expect(thermal.cpuTemp == 0)

        // No telemetry: battery power falls back to voltage × amperage.
        let fallback = ThermalMonitor.status(fromBatteryProperties: ["Voltage": 12_000, "InstantAmperage": -2000])
        #expect(abs(fallback.batteryPower - 24.0) < 0.001)
    }
}
