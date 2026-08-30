import Darwin
import Foundation

public enum ProcessMonitor {
    public enum SortMode {
        case cpu
        case memory
    }

    public struct ProcessInfo: Identifiable, Hashable, Sendable {
        public let id: Int
        public let pid: Int
        public let command: String
        public let cpuPercent: Double
        public let memoryPercent: Double
        public let residentBytes: Int64

        public init(pid: Int, command: String, cpuPercent: Double, memoryPercent: Double, residentBytes: Int64) {
            self.id = pid
            self.pid = pid
            self.command = command
            self.cpuPercent = cpuPercent
            self.memoryPercent = memoryPercent
            self.residentBytes = residentBytes
        }
    }

    /// A parsed `ps` row before the memory footprint (a separate per-pid
    /// syscall, not something `ps` reports) is attached.
    struct RawRow {
        let pid: Int
        let cpuPercent: Double
        let command: String
    }

    public static func top(sort: SortMode, limit: Int = 12) async -> [ProcessInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // pmem=/rss= dropped deliberately — see `footprint(pid:)`.
        process.arguments = ["-axo", "pid=,pcpu=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        // Read before waitUntilExit. `ps` output can exceed a pipe buffer on
        // busy systems; waiting first can deadlock the UI sheet indefinitely.
        guard let data = try? pipe.fileHandleForReading.readToEnd() else { return [] }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return [] }

        let totalMemory = Double(Foundation.ProcessInfo.processInfo.physicalMemory)
        let rows = output
            .split(separator: "\n")
            .compactMap(parseLine)
            .compactMap { raw -> ProcessInfo? in
                // Processes this call can't get a footprint for (different
                // user, SIP-protected, exited between `ps` sampling and this
                // lookup) are dropped rather than shown with a fabricated 0 —
                // a real memory hog silently reporting "0 bytes" is worse
                // than just not listing it.
                guard let bytes = footprint(pid: Int32(raw.pid)) else { return nil }
                let memPercent = totalMemory > 0 ? Double(bytes) / totalMemory * 100 : 0
                return ProcessInfo(
                    pid: raw.pid,
                    command: raw.command,
                    cpuPercent: raw.cpuPercent,
                    memoryPercent: memPercent,
                    residentBytes: Int64(bytes)
                )
            }

        let sorted: [ProcessInfo]
        switch sort {
        case .cpu:
            sorted = rows.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory:
            sorted = rows.sorted { $0.residentBytes > $1.residentBytes }
        }
        return Array(sorted.prefix(limit))
    }

    static func parseLine(_ line: Substring) -> RawRow? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3,
              let pid = Int(fields[0]),
              let cpu = Double(fields[1]) else { return nil }
        let command = URL(fileURLWithPath: String(fields[2])).lastPathComponent
        return RawRow(pid: pid, cpuPercent: cpu, command: command.isEmpty ? String(fields[2]) : command)
    }

    /// Real physical memory footprint for `pid`, in bytes — the same figure
    /// Activity Monitor's "Memory" column and Apple's own `/usr/bin/footprint`
    /// tool report (`ri_phys_footprint` via `proc_pid_rusage`, `RUSAGE_INFO_V4`).
    ///
    /// This used to come from `ps`'s `rss=` field (raw Resident Set Size),
    /// which is *why* this list never matched Activity Monitor side by side —
    /// RSS counts every shared framework page a process has mapped in full,
    /// so anything linking AppKit/WebKit/etc. (i.e. nearly everything) reads
    /// far higher under RSS than under the compressed-memory-aware,
    /// shared-page-excluded "footprint" Activity Monitor actually shows.
    /// Verified directly against `/usr/bin/footprint` on this machine: RSS
    /// and footprint disagreed by 2-3x on ordinary processes; this API and
    /// Apple's own tool agreed within a few KB (footprint fluctuates slightly
    /// between the two samples, same as it would between any two Activity
    /// Monitor refreshes).
    ///
    /// Returns nil if the pid can't be queried (different user, SIP-protected,
    /// or it exited between `ps` sampling and this call) rather than 0 — a
    /// silent 0 would misrepresent a process as using no memory instead of
    /// just being unreadable.
    static func footprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }
}
