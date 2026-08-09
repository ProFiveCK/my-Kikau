import Foundation

/// GPU collector. Ports Mole's `metrics_gpu.go` to native Swift.
///
/// Static GPU info comes from `system_profiler -json SPDisplaysDataType` (cached 10 min).
/// Real-time GPU usage comes from `powermetrics --samplers gpu_power` (cached 5s) but
/// requires root, so on a normal unprivileged app it returns -1 ("N/A").
/// `memoryUsed`/`memoryTotal` are not exposed by `system_profiler` on macOS and stay 0.
public enum GPUMonitor {

    /// Static GPU info cache TTL (seconds).
    public static let infoTTL: Double = 600

    /// Real-time GPU usage cache TTL (seconds).
    public static let usageTTL: Double = 5

    // MARK: - Collection

    /// Collects GPU statuses, using the provided box for caching.
    public static func collect(from box: GPUSampleBox, now: Date = Date()) -> [GPUStatus] {
        let nowTs = now.timeIntervalSince1970

        // Static GPU info (cached 10 min).
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

    // MARK: - GPU usage parsing (pure, tested)

    /// Parses `powermetrics --samplers gpu_power` output for GPU active residency.
    /// Returns the active residency percentage, or 100 - idle when only idle is present,
    /// or -1 when unavailable.
    public static func parseGPUUsage(_ output: String) -> Double {
        // "GPU HW active residency: X.XX%"
        if let pct = matchResidency(output, pattern: "GPU HW active residency:\\s+([\\d.]+)%") {
            return pct
        }
        // Fallback: "GPU idle residency: X.XX%" -> active = 100 - idle.
        if let idle = matchResidency(output, pattern: "GPU idle residency:\\s+([\\d.]+)%") {
            return 100.0 - idle
        }
        return -1
    }

    static func matchResidency(_ output: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        let captureRange = match.range(at: 1)
        guard let substringRange = Range(captureRange, in: output) else { return nil }
        return Double(output[substringRange])
    }

    // MARK: - subprocess

    /// Captures `system_profiler -json SPDisplaysDataType` output as Data.
    static func captureDisplaysJSON() -> Data? {
        guard let output = NetworkMonitor.runSync("/usr/sbin/system_profiler", ["-json", "SPDisplaysDataType"]) else {
            return nil
        }
        return output.data(using: .utf8)
    }

    /// Captures `powermetrics --samplers gpu_power -i 500 -n 1` and parses usage.
    /// Requires root; returns -1 when the command fails (normal for unprivileged apps).
    static func captureGPUUsage() -> Double {
        guard let output = NetworkMonitor.runSync("/usr/bin/powermetrics",
                                                   ["--samplers", "gpu_power", "-i", "500", "-n", "1"]) else {
            return -1
        }
        return parseGPUUsage(output)
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