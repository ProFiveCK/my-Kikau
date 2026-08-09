import Foundation
import Darwin

/// Per-interface network throughput collector.
/// Ports Mole's `metrics_network.go` to native Swift.
public enum NetworkMonitor {

    /// Interface name prefixes that are not real network traffic and should be ignored.
    /// Matches Mole's noise interface list.
    static let noisePrefixes = ["lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi", "ap"]

    /// Minimum interval between rate samples (seconds). Shorter calls return the previous rate.
    static let minInterval: Double = 0.1

    /// IP address cache TTL (seconds).
    static let ipCacheTTL: Double = 10

    /// Maximum number of interfaces surfaced (sorted by total rate descending).
    static let maxInterfaces = 3

    // MARK: - Public collection

    /// Collects per-interface network rates (MB/s). Maintains prev-sample state via the
    /// provided `box` so successive calls diff against the prior sample.
    public static func collect(into box: NetworkSampleBox, now: Date = Date()) -> [NetworkStatus] {
        let nowTs = now.timeIntervalSince1970
        guard box.lastAt == nil || nowTs - box.lastAt! >= minInterval else {
            return box.lastResults
        }

        guard let (rxByName, txByName) = readNetstatIB() else {
            return box.lastResults
        }

        // Build the current counter set, filtering noise interfaces.
        var current: [String: (rx: UInt64, tx: UInt64)] = [:]
        for (name, rx) in rxByName {
            guard !isNoiseInterface(name) else { continue }
            let tx = txByName[name] ?? 0
            current[name] = (rx: rx, tx: tx)
        }

        let elapsed: Double
        if let lastAt = box.lastAt, nowTs > lastAt {
            elapsed = nowTs - lastAt
        } else {
            elapsed = 0
        }

        // First sample primes state and returns empty.
        guard let prev = box.prev, elapsed > 0 else {
            box.prev = current
            box.lastAt = nowTs
            box.lastResults = []
            return []
        }

        var statuses: [NetworkStatus] = []
        for (name, cur) in current {
            let p = prev[name] ?? (rx: 0, tx: 0)
            let rxRate = rateMBs(current: cur.rx, previous: p.rx, elapsed: elapsed)
            let txRate = rateMBs(current: cur.tx, previous: p.tx, elapsed: elapsed)
            let ip = resolveIP(name: name, into: box, now: nowTs)
            statuses.append(NetworkStatus(name: name, rxRateMBs: rxRate, txRateMBs: txRate, ip: ip))
        }

        statuses.sort { ($0.rxRateMBs + $0.txRateMBs) > ($1.rxRateMBs + $1.txRateMBs) }
        if statuses.count > maxInterfaces {
            statuses = Array(statuses.prefix(maxInterfaces))
        }

        box.prev = current
        box.lastAt = nowTs
        box.lastResults = statuses
        return statuses
    }

    // MARK: - Pure helpers (tested)

    /// Returns true when the interface name matches a known noise prefix.
    public static func isNoiseInterface(_ name: String) -> Bool {
        for prefix in noisePrefixes where name.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Computes an MB/s rate from byte counters, guarding wraparound and negative deltas.
    public static func rateMBs(current: UInt64, previous: UInt64, elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        guard current >= previous else { return 0 }
        let delta = current - previous
        return Double(delta) / 1024 / 1024 / elapsed
    }

    // MARK: - netstat -ib parsing

    /// Parses `netstat -ib` output into per-interface (rx bytes by name, tx bytes by name).
    /// The `-b` flag adds Ibytes/Obytes columns. Returns nil when parsing fails entirely.
    public static func parseNetstatIB(_ output: String) -> (rxByName: [String: UInt64], txByName: [String: UInt64])? {
        var rxByName: [String: UInt64] = [:]
        var txByName: [String: UInt64] = [:]
        var sawHeader = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Header row: Name  Mtu  Network  Address  Ibytes  Obytes ...
            if trimmed.hasPrefix("Name") {
                sawHeader = true
                continue
            }
            guard sawHeader else { continue }

            // `netstat -ib` columns: Name(0) Mtu(1) Network(2) Address(3) Ibytes(4) Obytes(5) Errors(6) ...
            // The Address field may be a MAC address, IP, or "*" but never contains spaces,
            // so field positions stay stable. Require at least 6 fields.
            let fields = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 6 else { continue }

            let name = fields[0]
            guard !name.isEmpty, name != "Name" else { continue }

            guard let (rx, tx) = parseByteFields(fields) else { continue }

            rxByName[name, default: 0] += rx
            txByName[name, default: 0] += tx
        }

        guard sawHeader else { return nil }
        return (rxByName, txByName)
    }

    /// Extracts Ibytes(4)/Obytes(5) from a `netstat -ib` field array.
    static func parseByteFields(_ fields: [String]) -> (rx: UInt64, tx: UInt64)? {
        guard fields.count >= 6 else { return nil }
        guard let rx = UInt64(fields[4]), let tx = UInt64(fields[5]) else { return nil }
        return (rx, tx)
    }

    // MARK: - IP resolution via getifaddrs

    /// Resolves the primary IPv4 address for an interface, using a per-box cache.
    public static func resolveIP(name: String, into box: NetworkSampleBox, now: Double) -> String {
        if let cachedAt = box.lastIPAt, now - cachedAt < ipCacheTTL, let ip = box.cachedIPs[name] {
            return ip
        }
        refreshIPCache(into: box, now: now)
        return box.cachedIPs[name] ?? ""
    }

    /// Refreshes the cached interface→IP map via `getifaddrs`.
    public static func refreshIPCache(into box: NetworkSampleBox, now: Double) {
        var newCache: [String: String] = [:]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            box.cachedIPs = newCache
            box.lastIPAt = now
            return
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let addrPtr = entry.pointee.ifa_addr {
                let family = Int32(addrPtr.pointee.sa_family)
                if family == AF_INET || family == AF_INET6 {
                    let name = String(cString: entry.pointee.ifa_name)
                    if newCache[name] == nil {
                        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let addrLen = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                        if getnameinfo(addrPtr, addrLen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let host = String(cString: hostBuffer)
                            if !host.isEmpty, host != "::1", host != "127.0.0.1" {
                                newCache[name] = host
                            }
                        }
                    }
                }
            }
            cursor = entry.pointee.ifa_next
        }

        box.cachedIPs = newCache
        box.lastIPAt = now
    }

    // MARK: - subprocess

    /// Runs `netstat -ib` and returns parsed per-interface byte maps.
    private static func readNetstatIB() -> (rxByName: [String: UInt64], txByName: [String: UInt64])? {
        let out = runSync("/usr/sbin/netstat", ["-ib"])
        guard let output = out else { return nil }
        return parseNetstatIB(output)
    }

    /// Synchronous subprocess capture with a short timeout (best-effort).
    static func runSync(_ command: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Mutable box holding prev-sample state for network rate collection.
public final class NetworkSampleBox {
    public var prev: [String: (rx: UInt64, tx: UInt64)]?
    public var lastAt: Double?
    public var lastResults: [NetworkStatus] = []
    public var cachedIPs: [String: String] = [:]
    public var lastIPAt: Double?

    public init() {}
}