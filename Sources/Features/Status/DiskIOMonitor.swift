import Foundation
import IOKit

/// Disk IO rate collector. Ports Mole's `collectDiskIO` (`metrics_disk.go:475`) to native Swift.
///
/// Reads cumulative read/write byte counters via IOKit (`IOBlockStorageDriver` statistics),
/// diffs them against the previous sample to produce MB/s rates. The first sample primes
/// state and returns zero rates.
public enum DiskIOMonitor {

    // MARK: - Collection

    /// Collects disk IO rates, maintaining prev-sample state on the provided box.
    public static func collect(from box: DiskIOSampleBox, now: Date = Date()) -> DiskIOStatus {
        let (readBytes, writeBytes) = readCumulativeBytes()

        let nowTs = now.timeIntervalSince1970

        // First sample primes state and returns zero.
        guard let prev = box.prev, let lastAt = box.lastAt, nowTs > lastAt else {
            box.prev = (readBytes, writeBytes)
            box.lastAt = nowTs
            return DiskIOStatus()
        }

        let elapsed = nowTs - lastAt
        let status = diskIORates(currentRead: readBytes,
                                 currentWrite: writeBytes,
                                 previousRead: prev.read,
                                 previousWrite: prev.write,
                                 elapsed: elapsed)

        box.prev = (readBytes, writeBytes)
        box.lastAt = nowTs
        return status
    }

    // MARK: - Rate computation (pure, tested)

    /// Computes read/write MB/s rates from cumulative byte counters.
    /// Guards counter wraparound (returns 0 when current < previous) and clamps negatives.
    public static func diskIORates(
        currentRead: UInt64,
        currentWrite: UInt64,
        previousRead: UInt64,
        previousWrite: UInt64,
        elapsed: Double
    ) -> DiskIOStatus {
        guard elapsed > 0 else { return DiskIOStatus() }

        let readRate = rateMBs(current: currentRead, previous: previousRead, elapsed: elapsed)
        let writeRate = rateMBs(current: currentWrite, previous: previousWrite, elapsed: elapsed)
        return DiskIOStatus(readRate: readRate, writeRate: writeRate)
    }

    /// MB/s from byte counters, guarding wraparound. Negative results clamp to 0.
    static func rateMBs(current: UInt64, previous: UInt64, elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        guard current >= previous else { return 0 }
        let delta = current - previous
        return Double(delta) / 1024 / 1024 / elapsed
    }

    // MARK: - IOKit counters

    /// Sums cumulative read/write bytes across all `IOBlockStorageDriver` services.
    static func readCumulativeBytes() -> (read: UInt64, write: UInt64) {
        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        // The matching class and statistics key names are C macros in IOKit headers
        // (IOBlockStorageDriver.h) that are not bridged into Swift, so use the literals.
        let matching = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var service: io_object_t
        var next = IOIteratorNext(iterator)
        while next != 0 {
            service = next
            defer { IOObjectRelease(service) }

            if let statsRef = IORegistryEntryCreateCFProperty(service,
                                                              "Statistics" as CFString,
                                                              kCFAllocatorDefault,
                                                              0) {
                if let stats = statsRef.takeRetainedValue() as? [String: Any] {
                    totalRead += uint64(stats["Bytes (Read)"])
                    totalWrite += uint64(stats["Bytes (Written)"])
                }
            }
            next = IOIteratorNext(iterator)
        }

        return (totalRead, totalWrite)
    }

    /// Reads a UInt64 from a statistics dictionary entry (accepts NSNumber or String).
    static func uint64(_ value: Any?) -> UInt64 {
        if let n = value as? NSNumber { return n.uint64Value }
        if let s = value as? String, let v = UInt64(s) { return v }
        return 0
    }
}

/// Mutable box holding prev-sample state for disk IO rate collection.
public final class DiskIOSampleBox {
    public var prev: (read: UInt64, write: UInt64)?
    public var lastAt: Double?

    public init() {}
}