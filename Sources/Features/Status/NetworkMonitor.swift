import Foundation
import Darwin

/// Per-interface network throughput collector.
public enum NetworkMonitor {
    /// Interface name prefixes that are not real network traffic and should be ignored.
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

        guard let (rxByName, txByName) = readInterfaceCounters() else {
            return box.lastResults
        }

        // Build the current counter set, filtering noise interfaces.
        var current: [String: (rx: UInt64, tx: UInt64)] = [:]
        for (name, rx) in rxByName {
            guard !isNoiseInterface(name) else { continue }
            let tx = txByName[name] ?? 0
            current[name] = (rx: rx, tx: tx)
        }

        let elapsed: Double = if let lastAt = box.lastAt, nowTs > lastAt {
            nowTs - lastAt
        } else {
            0
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

    // MARK: - Interface counters

    /// Cumulative bytes in/out per interface, read straight from the kernel's
    /// routing table (`NET_RT_IFLIST2`) — the same source `netstat -ib` prints,
    /// with 64-bit counters and no subprocess.
    public static func readInterfaceCounters() -> (rxByName: [String: UInt64], txByName: [String: UInt64])? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var rxByName: [String: UInt64] = [:]
        var txByName: [String: UInt64] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        rxByName[name] = info.ifm_data.ifi_ibytes
                        txByName[name] = info.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        return rxByName.isEmpty ? nil : (rxByName, txByName)
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
