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

    public static func top(sort: SortMode, limit: Int = 12) async -> [ProcessInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,pmem=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else { return [] }

        let rows = output
            .split(separator: "\n")
            .compactMap(parseLine)

        let sorted: [ProcessInfo]
        switch sort {
        case .cpu:
            sorted = rows.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory:
            sorted = rows.sorted { $0.residentBytes > $1.residentBytes }
        }
        return Array(sorted.prefix(limit))
    }

    static func parseLine(_ line: Substring) -> ProcessInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard fields.count == 5,
              let pid = Int(fields[0]),
              let cpu = Double(fields[1]),
              let mem = Double(fields[2]),
              let rssKB = Int64(fields[3]) else { return nil }
        let command = URL(fileURLWithPath: String(fields[4])).lastPathComponent
        return ProcessInfo(
            pid: pid,
            command: command.isEmpty ? String(fields[4]) : command,
            cpuPercent: cpu,
            memoryPercent: mem,
            residentBytes: rssKB * 1024
        )
    }
}
