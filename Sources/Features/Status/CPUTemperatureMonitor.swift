import Foundation
import IOKit

/// Apple Silicon SoC die temperature, read via `IOHIDEventSystemClient` — the
/// same private-but-unentitled mechanism menu-bar monitors like Stats.app and
/// iStat Menus use on Apple Silicon. Apple Silicon Macs don't expose the
/// classic Intel `AppleSMC` "TC0P"-style keys at all, so that route (what
/// `ThermalMonitor`'s original comment refers to) never worked here.
///
/// This is a real sensor read, not a synthesized estimate — it doesn't
/// reintroduce the "false overheating readings" problem the original Mole
/// port avoided by leaving `cpuTemp` at 0. It only reports a temperature when
/// the SoC die sensors are actually present and readable; Intel Macs (and any
/// future HID sensor naming change) fall back to the same 0 = "unavailable"
/// sentinel `ThermalStatus.cpuTemp` already used.
public enum CPUTemperatureMonitor {
    private static let hidPageAppleVendor: Int64 = 0xff00
    private static let hidUsageAppleVendorTemperatureSensor: Int64 = 0x0005
    private static let eventTypeTemperature: Int64 = 15

    /// Averages all "tdie" (SoC die) sensors into one representative CPU
    /// package temperature in Celsius, using `box` to cache the matched
    /// sensor list so repeated polls don't re-enumerate HID services every
    /// 2 seconds. Averaging smooths per-cluster hotspots into a single figure
    /// rather than reporting one core's spike. "tdev" (case/skin), "tcal",
    /// battery, and storage sensors — exposed by the same HID service family
    /// — are excluded by the "tdie" name filter.
    public static func read(from box: CPUTempSampleBox) -> Double {
        let sensors = box.cachedDieSensors { matchDieSensors() }
        guard !sensors.isEmpty else { return 0 }

        var total = 0.0
        var count = 0
        for service in sensors {
            guard let eventRef = IOHIDServiceClientCopyEvent(service, eventTypeTemperature, 0, 0) else { continue }
            let value = IOHIDEventGetFloatValue(eventRef.takeRetainedValue(), Int32(eventTypeTemperature << 16))
            guard value > 0, value < 150 else { continue }
            total += value
            count += 1
        }
        guard count > 0 else { return 0 }
        return total / Double(count)
    }

    /// Creates a HID event system client matched to Apple's vendor-defined
    /// temperature sensor usage page, then filters to just the SoC "tdie"
    /// services. Returns the client alongside the filtered services so the
    /// caller can keep the client alive for as long as it holds onto them
    /// (the services are only valid while their owning client is retained).
    private static func matchDieSensors() -> (client: AnyObject, services: [AnyObject]) {
        let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault).takeRetainedValue()
        let match: [String: Any] = [
            "PrimaryUsagePage": hidPageAppleVendor,
            "PrimaryUsage": hidUsageAppleVendorTemperatureSensor
        ]
        IOHIDEventSystemClientSetMatching(client, match as CFDictionary)

        guard let servicesRef = IOHIDEventSystemClientCopyServices(client) else {
            return (client, [])
        }
        let all = servicesRef.takeRetainedValue() as [AnyObject]

        let dieSensors = all.filter { service in
            guard let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString) else { return false }
            let name = (nameRef.takeRetainedValue() as? String) ?? ""
            return name.lowercased().contains("tdie")
        }
        return (client, dieSensors)
    }
}

/// Mutable box holding the cached HID client + matched "tdie" sensor list.
/// The client is kept alive here (not just the services) because the
/// services remain valid only as long as their owning client is retained.
public final class CPUTempSampleBox {
    private var client: AnyObject?
    private var services: [AnyObject]?

    public init() {}

    func cachedDieSensors(match: () -> (client: AnyObject, services: [AnyObject])) -> [AnyObject] {
        if let services { return services }
        let result = match()
        client = result.client
        services = result.services
        return result.services
    }
}

// MARK: - Private IOHIDEventSystemClient bindings
//
// Undocumented but long-stable IOKit.framework symbols — not part of the
// public Swift IOKit module, so bound directly by symbol name (`@_silgen_name`).
// This is the same technique open-source Apple Silicon system monitors (e.g.
// exelban/stats) use to read these sensors without root. Safe here since
// myKikau is unsandboxed and distributed outside the Mac App Store (see
// myKikau.entitlements) — private-API restrictions are an App Review policy,
// not a runtime restriction.

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ match: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double
