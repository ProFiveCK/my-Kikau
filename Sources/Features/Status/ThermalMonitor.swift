import Foundation
import IOKit
import Core

/// Thermal and power collector.
///
/// Does NOT synthesize a CPU-package temperature from battery sensors or
/// `cpu_thermal_level` — those values are not CPU-package temperatures and
/// produce false overheating readings. `cpuTemp` is populated separately, by
/// `CPUTemperatureMonitor`, from real Apple Silicon die sensors (0 on Intel,
/// where that sensor family doesn't exist).
public enum ThermalMonitor {
    /// Cache TTL for the `system_profiler SPPowerDataType` fan-source output (seconds).
    public static let fanCacheTTL: Double = 300

    // MARK: - Collection

    /// Collects thermal + power metrics, using the provided box for fan-source caching.
    public static func collect(from box: ThermalSampleBox, now: Date = Date()) -> ThermalStatus {
        var thermal = ThermalStatus()

        // Fan speed from cached system_profiler output.
        let powerOutput = box.cachedPowerOutput(now: now) { capturePowerOutput() }
        if !powerOutput.isEmpty {
            let (speed, count) = parseFanSpeed(powerOutput)
            thermal.fanSpeed = speed
            thermal.fanCount = count
        }

        // Battery temp + power straight from the IORegistry — this runs on
        // every tick, so it must not spawn a process. `ioreg` text is only a
        // fallback for a registry read that fails.
        let battery: ThermalStatus? = if let properties = SmartBattery.properties() {
            status(fromBatteryProperties: properties)
        } else {
            captureIOReg().map(parseAppleSmartBatteryThermal)
        }
        if let battery {
            thermal.batteryTemp = battery.batteryTemp
            thermal.systemPower = battery.systemPower
            thermal.adapterPower = battery.adapterPower
            thermal.batteryPower = battery.batteryPower
        }

        return thermal
    }

    // MARK: - Fan parsing (pure, tested)

    /// Parses fan speed and fan count from `system_profiler SPPowerDataType` text output.
    /// Looks for lines containing both "fan" and "speed", then reads the integer after ":".
    public static func parseFanSpeed(_ output: String) -> (speed: Int, count: Int) {
        var speed = 0
        var count = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let lower = line.lowercased()
            guard lower.contains("fan"), lower.contains("speed") else { continue }
            if let colonRange = line.range(of: ":") {
                let after = line[colonRange.upperBound...]
                let trimmed = after.trimmingCharacters(in: .whitespaces)
                let numStr = trimmed.split(separator: " ").first.map(String.init) ?? ""
                if let value = Int(numStr.filter(\.isNumber)) {
                    if speed == 0 {
                        speed = value
                    }
                    count += 1
                }
            }
        }
        return (speed, count)
    }

    // MARK: - AppleSmartBattery properties (pure, tested)

    /// Builds thermal/power fields from the `AppleSmartBattery` registry
    /// entry's property dictionary. Same rules as the text parser below.
    public static func status(fromBatteryProperties properties: [String: Any]) -> ThermalStatus {
        var thermal = ThermalStatus()
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]

        // Centi-degrees Celsius (some machines report Celsius directly).
        if let temp = SmartBattery.double(properties["Temperature"]), temp > 0 {
            thermal.batteryTemp = temp < 1000 ? temp : temp / 100.0
        }
        if let adapter = properties["AdapterDetails"] as? [String: Any],
           let watts = SmartBattery.double(adapter["Watts"]), watts > 0
        {
            thermal.adapterPower = watts
        }
        if let powerMW = SmartBattery.double(telemetry["SystemPowerIn"]) {
            setSystemPowerMW(&thermal, powerMW)
        }
        if thermal.systemPower == 0,
           let powerMW = SmartBattery.double(telemetry["SystemPower"]) ?? SmartBattery.double(properties["SystemPower"])
        {
            setSystemPowerMW(&thermal, powerMW)
        }
        if let powerMW = SmartBattery.signed(telemetry["BatteryPower"]) ?? SmartBattery.signed(properties["BatteryPower"]) {
            setBatteryPowerMW(&thermal, powerMW)
        }

        // Fallback: derive battery power from voltage × amperage.
        if thermal.batteryPower == 0 {
            let voltageMV = SmartBattery.double(properties["AppleRawBatteryVoltage"])
                ?? SmartBattery.double(properties["Voltage"]) ?? 0
            let instant = SmartBattery.signed(properties["InstantAmperage"]) ?? 0
            let amperageMA = instant != 0 ? instant : (SmartBattery.signed(properties["Amperage"]) ?? 0)
            if voltageMV > 0, amperageMA != 0 {
                // Signed mA: negative current = discharging, so keep
                // BatteryPower positive for discharge.
                let batteryPowerW = -(voltageMV * amperageMA) / 1_000_000.0
                if batteryPowerW > -200, batteryPowerW < 200 {
                    thermal.batteryPower = batteryPowerW
                }
            }
        }
        return thermal
    }

    // MARK: - AppleSmartBattery parsing (pure, tested)

    /// Parses `ioreg -rn AppleSmartBattery` output into thermal/power fields.
    public static func parseAppleSmartBatteryThermal(_ output: String) -> ThermalStatus {
        var thermal = ThermalStatus()
        var voltageMV: Double = 0
        var amperageMA: Double = 0

        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)

            // Battery temperature in centi-degrees Celsius (some fixtures report Celsius directly).
            if let tempRaw = ioRegFloat(line, "Temperature"), tempRaw > 0 {
                thermal.batteryTemp = tempRaw < 1000 ? tempRaw : tempRaw / 100.0
            }

            // Adapter power (Watts). Ignore AppleRawAdapterDetails entries: raw entries can
            // appear before the normalized adapter details and should not win the display value.
            if line.contains("\"AdapterDetails\""), !line.contains("AppleRaw"), thermal.adapterPower == 0 {
                if let watts = ioRegFloat(line, "Watts"), watts > 0 {
                    thermal.adapterPower = watts
                }
            }

            // System power consumption (mW -> W).
            if let powerMW = ioRegFloat(line, "SystemPowerIn") {
                setSystemPowerMW(&thermal, powerMW)
            }
            if thermal.systemPower == 0, let powerMW = ioRegFloat(line, "SystemPower") {
                setSystemPowerMW(&thermal, powerMW)
            }

            // Battery power (mW -> W; positive = discharging, negative = charging).
            if let powerMW = ioRegSignedNumber(line, "BatteryPower") {
                setBatteryPowerMW(&thermal, powerMW)
            }

            if let voltage = ioRegFloat(line, "Voltage"), voltage > 0 {
                voltageMV = voltage
            }
            if let voltage = ioRegFloat(line, "AppleRawBatteryVoltage"), voltage > 0 {
                voltageMV = voltage
            }
            if let amperage = ioRegSignedNumber(line, "InstantAmperage"), amperage != 0 {
                amperageMA = amperage
            }
            if amperageMA == 0, let amperage = ioRegSignedNumber(line, "Amperage"), amperage != 0 {
                amperageMA = amperage
            }
        }

        // Fallback: derive battery power from voltage × amperage when BatteryPower was absent.
        if thermal.batteryPower == 0, voltageMV > 0, amperageMA != 0 {
            // AppleSmartBattery amperage is signed mA. Negative current = discharging,
            // so keep BatteryPower positive for discharge.
            let batteryPowerW = -(voltageMV * amperageMA) / 1_000_000.0
            if batteryPowerW > -200, batteryPowerW < 200 {
                thermal.batteryPower = batteryPowerW
            }
        }
        return thermal
    }

    // MARK: - ioreg line helpers (pure)

    /// Extracts the numeric value for `key` from an ioreg line of the form `"Key" = Value`.
    static func ioRegFloat(_ line: String, _ key: String) -> Double? {
        guard let raw = ioRegValueForKey(line, key) else { return nil }
        return Double(raw)
    }

    /// Extracts a signed numeric value for `key`, accepting both int and uint forms
    /// (ioreg sometimes prints negative int64 as uint64 two's-complement).
    static func ioRegSignedNumber(_ line: String, _ key: String) -> Double? {
        guard let raw = ioRegValueForKey(line, key) else { return nil }
        if let v = Int64(raw) {
            return Double(v)
        }
        if let v = UInt64(raw), v <= UInt64(Int64.max) {
            return Double(Int64(v))
        }
        return nil
    }

    /// Returns the raw string token after `"Key" =` in an ioreg line, or nil.
    /// Scans for the value terminator (`,`, `}`, `)`, space, tab, newline),
    /// then strips surrounding quotes.
    static func ioRegValueForKey(_ line: String, _ key: String) -> String? {
        let marker = "\"\(key)\""
        guard let markerRange = line.range(of: marker) else { return nil }
        var rest = line[markerRange.upperBound...]
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.hasPrefix("=") else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        guard !rest.isEmpty, rest.first != "," else { return nil }

        let terminators: Set<Character> = [",", "}", ")", " ", "\t", "\n", "\r"]
        var end = rest.startIndex
        for i in rest.indices {
            if terminators.contains(rest[i]) {
                break
            }
            end = rest.index(after: i)
        }
        var value = String(rest[rest.startIndex ..< end])
        if value.hasPrefix("\"") {
            value.removeFirst()
        }
        if value.hasSuffix("\"") {
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }
        return value
    }

    static func setSystemPowerMW(_ thermal: inout ThermalStatus, _ powerMW: Double) {
        // SystemPower should always be positive; reject values outside 0–1000W.
        if powerMW >= 0, powerMW < 1_000_000 {
            thermal.systemPower = powerMW / 1000.0
        }
    }

    static func setBatteryPowerMW(_ thermal: inout ThermalStatus, _ powerMW: Double) {
        // Validate a reasonable battery power range: -200W to 200W.
        if powerMW > -200_000, powerMW < 200_000 {
            thermal.batteryPower = powerMW / 1000.0
        }
    }

    // MARK: - subprocess

    /// Captures `system_profiler SPPowerDataType` text output (no -json, used for fan parsing).
    static func capturePowerOutput() -> String {
        let output = ProcessRunner.runBlocking("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 20)
        return output.succeeded ? output.stdout : ""
    }

    /// Captures `ioreg -rn AppleSmartBattery` output.
    static func captureIOReg() -> String? {
        let output = ProcessRunner.runBlocking("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"], timeout: 10)
        return output.succeeded && !output.stdout.isEmpty ? output.stdout : nil
    }
}

/// Reads the `AppleSmartBattery` IORegistry entry in-process.
public enum SmartBattery {
    /// The entry's full property dictionary, or `nil` on a Mac without a
    /// battery (or if the registry read fails).
    public static func properties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    /// Battery wear, from the same dictionary.
    public struct Health: Equatable, Sendable {
        public let cycleCount: Int
        /// Full-charge capacity as a percentage of design capacity; 0 = unknown.
        public let capacityPercent: Int
    }

    public static func health(from properties: [String: Any]) -> Health {
        // Newer macOS releases moved the capacity figures into a nested
        // "BatteryData" dictionary; older ones keep them at the top level.
        let nested = properties["BatteryData"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Double? {
            double(properties[key]) ?? double(nested[key])
        }
        let cycles = Int(value("CycleCount") ?? 0)
        let design = value("DesignCapacity") ?? 0
        // `MaxCapacity` is a percentage on Apple Silicon and mAh on Intel;
        // the raw / nominal keys are always mAh.
        let maxCapacity = value("MaxCapacity") ?? 0
        let fullCharge = value("AppleRawMaxCapacity")
            ?? value("NominalChargeCapacity")
            ?? (maxCapacity > 100 ? maxCapacity : nil)
        var percent = 0
        if let fullCharge, design > 0 {
            // A new battery can hold slightly more than its rated capacity.
            percent = min(100, max(0, Int((fullCharge / design * 100).rounded())))
        }
        return Health(cycleCount: max(0, cycles), capacityPercent: percent)
    }

    static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Signed reading. The registry sometimes stores a negative int64 as an
    /// unsigned value; `int64Value` reinterprets the bits correctly.
    static func signed(_ value: Any?) -> Double? {
        (value as? NSNumber).map { Double($0.int64Value) }
    }
}

/// Mutable box holding fan-source cache for thermal collection.
public final class ThermalSampleBox {
    private var cachedPower: String = ""
    private var lastAt: Double?

    public init() {}

    /// Returns cached power output when fresh, otherwise invokes `capture`.
    func cachedPowerOutput(now: Date, capture: () -> String) -> String {
        let nowTs = now.timeIntervalSince1970
        if !cachedPower.isEmpty, let lastAt, nowTs - lastAt < ThermalMonitor.fanCacheTTL {
            return cachedPower
        }
        let fresh = capture()
        if !fresh.isEmpty {
            cachedPower = fresh
            lastAt = nowTs
        }
        return cachedPower
    }
}
