import Foundation

/// Append-only JSONL operation log. Mirrors Mole's `~/Library/Logs/mole/operations.log`.
/// Each line is a structured record of a file operation (trash/permanent, size, outcome).
public final class OperationLog {
    public static let shared = OperationLog()

    private let logURL: URL
    private let queue = DispatchQueue(label: "myKikau.oplog")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// User-facing toggle. When false, no entries are written.
    public var enabled: Bool

    public init(logURL: URL? = nil, enabled: Bool = true) {
        if let url = logURL {
            self.logURL = url
        } else {
            let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Logs/myKikau", isDirectory: true)
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            self.logURL = logsDir.appendingPathComponent("operations.log")
        }
        self.enabled = enabled
    }

    public enum Mode: String, Codable {
        case trash
        case permanent
    }

    public enum Outcome: String, Codable {
        case success
        case failed
        case skipped
        case dryRun
    }

    public struct Entry: Codable, Identifiable {
        public var id: String { "\(timestamp.timeIntervalSince1970)-\(path)" }
        public let timestamp: Date
        public let action: String
        public let path: String
        public let sizeBytes: Int64
        public let mode: Mode
        public let outcome: Outcome
        public let dryRun: Bool
        public let detail: String?

        public init(
            timestamp: Date = Date(),
            action: String,
            path: String,
            sizeBytes: Int64,
            mode: Mode,
            outcome: Outcome,
            dryRun: Bool,
            detail: String? = nil
        ) {
            self.timestamp = timestamp
            self.action = action
            self.path = path
            self.sizeBytes = sizeBytes
            self.mode = mode
            self.outcome = outcome
            self.dryRun = dryRun
            self.detail = detail
        }
    }

    public func append(_ entry: Entry) {
        guard enabled else { return }
        queue.async { [logURL, encoder] in
            guard let data = try? encoder.encode(entry) else { return }
            var line = data
            line.append(0x0A) // newline
            // Append atomically; if the file doesn't exist, create it.
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                }
            } else {
                try? line.write(to: logURL)
            }
        }
    }

    /// Reads recent log entries (newest first).
    public func recent(limit: Int = 200) -> [Entry] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A)
        var entries: [Entry] = []
        for line in lines.suffix(limit) {
            if let entry = try? decoder.decode(Entry.self, from: Data(line)) {
                entries.append(entry)
            }
        }
        return entries.reversed()
    }

    /// Returns the total bytes freed by successful (non-dryRun) operations.
    public func totalFreed() -> Int64 {
        recent(limit: 10000)
            .filter { $0.outcome == .success && !$0.dryRun }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    /// Clears the log file.
    public func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }
}