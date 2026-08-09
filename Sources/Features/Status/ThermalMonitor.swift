import Foundation

/// Thermal and power collector.
/// Ports Mole's `collectThermal` (`metrics_battery.go:344`) to native Swift.
///
/// `cpuTemp` is intentionally left at 0. Mole deliberately does NOT synthesize a
/// CPU-package temperature from battery sensors or `cpu_thermal_level`, because those
/// values are not CPU-package temperatures and produce false overheating readings.
public enum ThermalMonitor {

    /// Cache TTL for the `system_profiler SPPowerDataType` fan-source output (seconds).
    public static let fanCacheTTL: Double = 60

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

        // Battery temp + power from ioreg (fast, real-time).
        if let ioregOutput = captureIOReg() {
            let battery = parseAppleSmartBatteryThermal(ioregOutput)
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
                if let value = Int(numStr.filter { $0.isNumber }) {
                    if speed == 0 { speed = value }
                    count += 1
                }
            }
        }
        return (speed, count)
    }

    // MARK: - AppleSmartBattery parsing (pure, tested)

    /// Parses `ioreg -rn AppleSmartBattery` output into thermal/power fields.
    /// Mirrors Mole's `parseAppleSmartBatteryThermal`.
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

            if let voltage = ioRegFloat(line, "Voltage"), voltage > 0 { voltageMV = voltage }
            if let voltage = ioRegFloat(line, "AppleRawBatteryVoltage"), voltage > 0 { voltageMV = voltage }
            if let amperage = ioRegSignedNumber(line, "InstantAmperage"), amperage != 0 { amperageMA = amperage }
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
        if let v = Int64(raw) { return Double(v) }
        if let v = UInt64(raw), v <= UInt64(Int64.max) { return Double(Int64(v)) }
        return nil
    }

    /// Returns the raw string token after `"Key" =` in an ioreg line, or nil.
    /// Scans for the value terminator (`,`, `}`, `)`, space, tab, newline) like Mole's
    /// `ioRegValueForKey`, then strips surrounding quotes.
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
            if terminators.contains(rest[i]) { break }
            end = rest.index(after: i)
        }
        var value = String(rest[rest.startIndex..<end])
        if value.hasPrefix("\"") { value.removeFirst() }
        if value.hasSuffix("\"") { value.removeLast() }
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
        NetworkMonitor.runSync("/usr/sbin/system_profiler", ["SPPowerDataType"]) ?? ""
    }

    /// Captures `ioreg -rn AppleSmartBattery` output.
    static func captureIOReg() -> String? {
        NetworkMonitor.runSync("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"])
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
        if !cachedPower.isEmpty, let lastAt = lastAt, nowTs - lastAt < ThermalMonitor.fanCacheTTL {
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