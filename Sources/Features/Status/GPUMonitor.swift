import Foundation
import IOKit
import Core

/// GPU collector.
///
/// Static GPU info comes from `system_profiler -json SPDisplaysDataType` (cached for hours — the hardware doesn't change).
/// Real-time GPU usage is read directly from IORegistry (`IOAccelerator`'s
/// `PerformanceStatistics`) — this works for any unprivileged process. When the
/// key isn't present on a given macOS/GPU combination, usage reads as -1.
/// `memoryUsed`/`memoryTotal` are not exposed by `system_profiler` on macOS and stay 0.
public enum GPUMonitor {

    /// Static GPU info cache TTL (seconds).
    public static let infoTTL: Double = 6 * 3600

    /// Real-time GPU usage cache TTL (seconds).
    public static let usageTTL: Double = 5

    // MARK: - Collection

    /// Collects GPU statuses, using the provided box for caching.
    public static func collect(from box: GPUSampleBox, now: Date = Date()) -> [GPUStatus] {
        let nowTs = now.timeIntervalSince1970

        // Static GPU info (cached for hours — the hardware doesn't change).
        if box.cachedGPU.isEmpty || box.lastInfoAt == nil || nowTs - box.lastInfoAt! >= infoTTL {
            if let data = captureDisplaysJSON(),
               let gpus = parseDisplaysJSON(data), !gpus.isEmpty {
                box.cachedGPU = gpus
                box.lastInfoAt = nowTs
            }
        }

        guard !box.cachedGPU.isEmpty else { return [] }

        // Real-time GPU usage (cached 5s).
        var usage: Double = -1
        if box.lastUsageAt == nil || nowTs - box.lastUsageAt! >= usageTTL {
            usage = captureGPUUsage()
            box.cachedUsage = usage
            box.lastUsageAt = nowTs
        } else {
            usage = box.cachedUsage
        }

        var result = box.cachedGPU
        // Apply usage to the first GPU (Apple Silicon integrated GPU).
        if !result.isEmpty {
            result[0].usage = usage
        }
        return result
    }

    // MARK: - Static info parsing (pure, tested)

    /// Parses `system_profiler -json SPDisplaysDataType` JSON into GPU statuses.
    public static func parseDisplaysJSON(_ data: Data) -> [GPUStatus]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let displays = root["SPDisplaysDataType"] as? [[String: Any]] else { return nil }

        var gpus: [GPUStatus] = []
        for d in displays {
            let name = (d["_name"] as? String) ?? ""
            if name.isEmpty { continue }

            let vram = d["spdisplays_vram"] as? String
            let vendor = d["spdisplays_vendor"] as? String
            let metal = d["spdisplays_metal"] as? String
            let coresStr = d["sppci_cores"] as? String
            let cores = Int(coresStr ?? "") ?? 0

            var noteParts: [String] = []
            if let v = vram, !v.isEmpty { noteParts.append("VRAM " + v) }
            if let m = metal, !m.isEmpty { noteParts.append(m) }
            if let v = vendor, !v.isEmpty { noteParts.append(v) }
            let note = noteParts.joined(separator: " · ")

            gpus.append(GPUStatus(name: name, usage: -1, coreCount: cores, note: note))
        }

        if gpus.isEmpty { return nil }
        return gpus
    }

    // MARK: - subprocess

    /// Captures `system_profiler -json SPDisplaysDataType` output as Data.
    static func captureDisplaysJSON() -> Data? {
        let output = ProcessRunner.runBlocking("/usr/sbin/system_profiler", ["-json", "SPDisplaysDataType"], timeout: 20)
        return output.succeeded ? output.stdout.data(using: .utf8) : nil
    }

    /// Captures live GPU usage from IORegistry, or -1 when this GPU/macOS
    /// combination doesn't publish it. (The only other source, `powermetrics`,
    /// needs root — which myKikau never has — so there is no fallback.)
    static func captureGPUUsage() -> Double {
        captureGPUUsageViaIOKit()
    }

    /// Reads live GPU utilization from IORegistry's `IOAccelerator` service —
    /// the same mechanism menu-bar system monitors (e.g. Stats, iStat Menus)
    /// use, and unlike `powermetrics`, it doesn't require root. Returns -1 if
    /// the expected key isn't present (e.g. a macOS version that names it
    /// differently) so callers fall back cleanly rather than showing a wrong number.
    static func captureGPUUsageViaIOKit() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return -1
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var propsUnmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsUnmanaged?.takeRetainedValue() as? [String: Any],
                  let perfStats = props["PerformanceStatistics"] as? [String: Any] else {
                continue
            }

            // Key name has drifted across macOS versions in the wild; check
            // the known variants rather than betting on just one.
            for key in ["Device Utilization %", "GPU Activity(%)", "GPU Core Utilization"] {
                if let value = perfStats[key] as? Int {
                    return Double(value)
                }
                if let value = perfStats[key] as? Double {
                    return value
                }
            }
        }
        return -1
    }
}

/// Mutable box holding GPU caching state.
public final class GPUSampleBox {
    public var cachedGPU: [GPUStatus] = []
    public var lastInfoAt: Double?
    public var cachedUsage: Double = -1
    public var lastUsageAt: Double?

    public init() {}
}
