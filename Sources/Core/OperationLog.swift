import CryptoKit
import Foundation

/// Append-only JSONL operation log.
/// Each line is a structured record of a file operation (trash/permanent, size, outcome).
///
/// Audit properties:
/// - **Hash chain.** Every entry records the SHA-256 of the line before it
///   (`prevHash`), so an edited, removed or reordered line is detectable with
///   `verifyChain()`.
/// - **Rotation.** The file rolls over at `maxFileBytes`; `rotatedFilesKept`
///   older files are retained alongside it (`operations.1.log` is the newest).
/// - **Running totals** live in a sidecar file, so "freed to date" survives
///   rotation and doesn't require decoding the whole log.
/// - The log's own folder is a protected path, so no cleanup can remove it.
public final class OperationLog: @unchecked Sendable {
    public static let shared = OperationLog(
        logURL: sharedLogURLOverride(),
        enabled: AppDefaults.store.object(forKey: AppStorageKey.operationLogEnabled) as? Bool ?? true,
        persistsEnabled: true
    )

    /// The real log in `~/Library/Logs/myKikau` belongs to myKikau's own
    /// processes — the app and its command-line tool. Any other host of this
    /// code (the test runner, above all) gets a throwaway log instead, so the
    /// user's audit trail and "freed to date" total never pick up entries
    /// that aren't theirs.
    private static func sharedLogURLOverride() -> URL? {
        let executable = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? ""
        let isOwnProcess = Bundle.main.bundleIdentifier == AppDefaults.appDomain
            || ["myKikau", "mykikau-cli"].contains(executable)
        if isOwnProcess {
            return nil
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("myKikau-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        return dir.appendingPathComponent("operations.log")
    }

    public static let maxFileBytes = 5_000_000
    public static let rotatedFilesKept = 5

    private let logURL: URL
    private let totalsURL: URL
    private let persistsEnabled: Bool
    private let maxFileBytes: Int
    private let queue = DispatchQueue(label: "myKikau.oplog")
    private let stateLock = NSLock()
    private var storedEnabled: Bool
    /// Hash of the last line written. Queue-confined; loaded lazily.
    private var lastLineHash: String?
    private var lastLineHashLoaded = false
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// User-facing toggle. When false, no entries are written — unless an
    /// administrator forces logging on (`ManagedPolicy.forceOperationLog`).
    public var enabled: Bool {
        get {
            if persistsEnabled, ManagedPolicy.shared.forceOperationLog {
                return true
            }
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedEnabled
        }
        set {
            stateLock.lock()
            storedEnabled = newValue
            stateLock.unlock()
            if persistsEnabled {
                AppDefaults.store.set(newValue, forKey: AppStorageKey.operationLogEnabled)
            }
        }
    }

    /// The log file's location on disk — used by "Reveal Log File".
    public var fileURL: URL {
        logURL
    }

    public convenience init(logURL: URL? = nil, enabled: Bool = true) {
        self.init(logURL: logURL, enabled: enabled, persistsEnabled: false)
    }

    public init(logURL: URL?, enabled: Bool, persistsEnabled: Bool, maxFileBytes: Int = OperationLog.maxFileBytes) {
        if let url = logURL {
            self.logURL = url
        } else {
            let logsDir = (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"))
                .appendingPathComponent("Logs/myKikau", isDirectory: true)
            self.logURL = logsDir.appendingPathComponent("operations.log")
        }
        totalsURL = self.logURL.deletingPathExtension().appendingPathExtension("totals.json")
        storedEnabled = enabled
        self.persistsEnabled = persistsEnabled
        self.maxFileBytes = maxFileBytes
    }

    public enum Mode: String, Codable, Sendable {
        case trash
        case permanent
    }

    public enum Outcome: String, Codable, Sendable, CaseIterable {
        case success
        case failed
        case skipped
        case dryRun
    }

    public struct Entry: Codable, Identifiable, Sendable {
        public var id: String {
            "\(timestamp.timeIntervalSince1970)-\(action)-\(path)"
        }

        public let sessionID: UUID?
        public let timestamp: Date
        public let action: String
        public let path: String
        public let sizeBytes: Int64
        public let mode: Mode
        public let outcome: Outcome
        public let dryRun: Bool
        public let detail: String?
        /// Where the item landed in the Trash, when it was trashed — what
        /// "Put Back" moves home again.
        public let trashedPath: String?
        /// The trashed item's file number (inode). Put Back checks it, so an
        /// old entry can never restore a *different* item that later landed
        /// at the same Trash path.
        public let trashedFileNumber: UInt64?
        /// SHA-256 of the previous log line. Set by `append`.
        public var prevHash: String?

        public init(
            timestamp: Date = Date(),
            sessionID: UUID? = nil,
            action: String,
            path: String,
            sizeBytes: Int64,
            mode: Mode,
            outcome: Outcome,
            dryRun: Bool,
            detail: String? = nil,
            trashedPath: String? = nil,
            trashedFileNumber: UInt64? = nil
        ) {
            self.sessionID = sessionID
            self.timestamp = timestamp
            self.action = action
            self.path = path
            self.sizeBytes = sizeBytes
            self.mode = mode
            self.outcome = outcome
            self.dryRun = dryRun
            self.detail = detail
            self.trashedPath = trashedPath
            self.trashedFileNumber = trashedFileNumber
        }
    }

    /// Separate historical activity totals across rotations. Neither counter is
    /// a measurement of current free disk space.
    public struct Totals: Codable, Equatable, Sendable {
        /// Historical bytes permanently removed, not measured free-space gain.
        public var freedBytes: Int64
        /// Historical Trash moves, not the current size of the Trash.
        public var trashedBytes: Int64
        /// Older versions mixed Trash moves and permanent removals. Preserve
        /// that value without presenting it as classified or freed space.
        public var legacyProcessedBytes: Int64
        public var operations: Int
        public var lastHash: String?
        public var accountingVersion: Int = 2

        public init(
            freedBytes: Int64 = 0,
            operations: Int = 0,
            lastHash: String? = nil,
            trashedBytes: Int64 = 0,
            legacyProcessedBytes: Int64 = 0
        ) {
            self.freedBytes = freedBytes
            self.trashedBytes = trashedBytes
            self.legacyProcessedBytes = legacyProcessedBytes
            self.operations = operations
            self.lastHash = lastHash
        }

        private enum CodingKeys: String, CodingKey {
            case freedBytes, trashedBytes, legacyProcessedBytes, operations, lastHash, accountingVersion
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            operations = try c.decode(Int.self, forKey: .operations)
            lastHash = try c.decodeIfPresent(String.self, forKey: .lastHash)
            let previous = try c.decodeIfPresent(Int64.self, forKey: .freedBytes) ?? 0
            if try c.decodeIfPresent(Int.self, forKey: .accountingVersion) == 2 {
                freedBytes = previous
                trashedBytes = try c.decodeIfPresent(Int64.self, forKey: .trashedBytes) ?? 0
                legacyProcessedBytes = try c.decodeIfPresent(Int64.self, forKey: .legacyProcessedBytes) ?? 0
            } else {
                freedBytes = 0
                trashedBytes = 0
                legacyProcessedBytes = previous
            }
        }

        mutating func record(_ entry: Entry) {
            operations += 1
            guard entry.outcome == .success, !entry.dryRun, !entry.path.isEmpty,
                  entry.action != "putBack" else { return }
            if entry.mode == .permanent {
                freedBytes += max(0, entry.sizeBytes)
            } else {
                trashedBytes += max(0, entry.sizeBytes)
            }
        }
    }

    /// Result of `verifyChain()`.
    public struct ChainStatus: Equatable, Sendable {
        /// Entries whose `prevHash` matched the line before them.
        public let verified: Int
        /// Entries that can't be checked: written before hash chaining
        /// existed, or the first line of a file.
        public let unchained: Int
        /// 1-based line number of the first entry that doesn't match, if any.
        public let firstBrokenLine: Int?
        /// Entries are missing from the start or the end of the file.
        public var truncated: Bool = false

        public var isIntact: Bool {
            firstBrokenLine == nil && !truncated
        }
    }

    // MARK: - Writing

    public func append(_ entry: Entry) {
        guard enabled else { return }
        Log.audit.notice(
            """
            \(entry.action, privacy: .public) \(entry.outcome.rawValue, privacy: .public) \
            \(entry.mode.rawValue, privacy: .public) \(entry.sizeBytes, privacy: .public)B \
            dryRun=\(entry.dryRun, privacy: .public) path=\(entry.path, privacy: .private) \
            \(entry.detail ?? "", privacy: .private)
            """
        )
        queue.async { [self] in
            write(entry)
        }
    }

    /// Blocks until every queued entry is on disk.
    public func flush() {
        queue.sync {}
    }

    private func write(_ entry: Entry) {
        let fm = FileManager.default
        // Recreate the folder if something removed it since launch — otherwise
        // every later entry would be dropped silently.
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()

        var chained = entry
        chained.prevHash = currentLastLineHash()
        guard let data = try? encoder.encode(chained) else { return }
        var line = data
        line.append(0x0A)

        do {
            if fm.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: logURL)
            }
        } catch {
            // The audit trail is missing an entry — make that visible somewhere.
            Log.app.error("operation log write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        lastLineHash = Self.hash(data)
        lastLineHashLoaded = true

        var totals = loadTotals(excludingLastLine: true)
        totals.record(entry)
        totals.lastHash = lastLineHash
        saveTotals(totals)
    }

    private func currentLastLineHash() -> String? {
        if lastLineHashLoaded {
            return lastLineHash
        }
        lastLineHashLoaded = true
        lastLineHash = tailLines(of: logURL, limit: 1).last.map(Self.hash)
        return lastLineHash
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size >= maxFileBytes else {
            return
        }
        // The chain continues across the boundary: the first line of the new
        // file records the hash of the last line of the rotated one.
        _ = currentLastLineHash()
        try? fm.removeItem(at: rotatedURL(Self.rotatedFilesKept))
        for index in stride(from: Self.rotatedFilesKept - 1, through: 1, by: -1) {
            let from = rotatedURL(index)
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: rotatedURL(index + 1))
            }
        }
        try? fm.moveItem(at: logURL, to: rotatedURL(1))
    }

    private func rotatedURL(_ index: Int) -> URL {
        logURL.deletingPathExtension().appendingPathExtension("\(index).log")
    }

    // MARK: - Reading

    /// Reads recent log entries (newest first) from the current file.
    public func recent(limit: Int = 200) -> [Entry] {
        queue.sync {
            let decoder = Self.makeDecoder()
            return tailLines(of: logURL, limit: limit)
                .compactMap { try? decoder.decode(Entry.self, from: $0) }
                .reversed()
        }
    }

    /// All retained rotations participate, so a cleanup isn't split at the
    /// current-file boundary. Old ungrouped entries retain individual Put Back.
    public func cleanupSessions(limit: Int = 20) -> [CleanupSession] {
        queue.sync {
            let decoder = Self.makeDecoder()
            let files = (1 ... Self.rotatedFilesKept).reversed().map(rotatedURL) + [logURL]
            let entries = files.flatMap { tailLines(of: $0, limit: .max) }
                .compactMap { try? decoder.decode(Entry.self, from: $0) }
                .filter { $0.sessionID != nil && !$0.dryRun && $0.action != "putBack" && !$0.path.isEmpty }
            let groups = Dictionary(grouping: entries, by: { $0.sessionID! })
            return Array(groups.map { CleanupSession(id: $0.key, entries: $0.value) }
                .sorted { $0.date > $1.date }.prefix(max(0, limit)))
        }
    }

    /// Historical bytes permanently removed. Trash moves are counted separately;
    /// filesystem snapshots and other activity can affect actual free space.
    public func totalFreed() -> Int64 {
        totals().freedBytes
    }

    public func totals() -> Totals {
        queue.sync { loadTotals(excludingLastLine: false) }
    }

    /// Checks the current log file:
    /// - every entry's `prevHash` matches the entry before it (an edit, an
    ///   insertion or a removal in the middle breaks this);
    /// - the first entry links to the last entry of the previous rotated
    ///   file, or to nothing if this is where the log starts (entries removed
    ///   from the start break this);
    /// - the last entry matches the hash recorded in the totals sidecar
    ///   (entries removed from the end break this).
    ///
    /// This detects tampering with the log file. It can't stop someone who
    /// rewrites the log *and* the sidecar consistently; for that, ship the
    /// log off the machine.
    public func verifyChain() -> ChainStatus {
        queue.sync {
            let decoder = Self.makeDecoder()
            let lines = tailLines(of: logURL, limit: .max)
            var verified = 0
            var unchained = 0
            var truncated = false
            for (index, line) in lines.enumerated() {
                guard let entry = try? decoder.decode(Entry.self, from: line) else {
                    return ChainStatus(verified: verified, unchained: unchained, firstBrokenLine: index + 1)
                }
                if index == 0 {
                    let previousFileTail = tailLines(of: rotatedURL(1), limit: 1).last
                    if let prev = entry.prevHash {
                        // Must be the tail of the previous file. If that file
                        // is gone, earlier entries are missing.
                        if let previousFileTail {
                            if prev != Self.hash(previousFileTail) {
                                return ChainStatus(verified: verified, unchained: unchained, firstBrokenLine: 1)
                            }
                            verified += 1
                        } else {
                            truncated = true
                            unchained += 1
                        }
                    } else {
                        // A legacy entry, or the first line of a new log.
                        unchained += 1
                    }
                    continue
                }
                guard let prev = entry.prevHash else {
                    unchained += 1
                    continue
                }
                if prev != Self.hash(lines[index - 1]) {
                    return ChainStatus(verified: verified, unchained: unchained, firstBrokenLine: index + 1)
                }
                verified += 1
            }
            if let recorded = storedTotals()?.lastHash {
                let actual = lines.last.map(Self.hash)
                if actual != recorded {
                    truncated = true
                }
            }
            return ChainStatus(verified: verified, unchained: unchained, firstBrokenLine: nil, truncated: truncated)
        }
    }

    public enum ExportFormat: String, CaseIterable, Sendable {
        case jsonl
        case csv
    }

    /// Writes every retained entry (rotated files first, oldest to newest) to
    /// `destination` as JSONL or CSV.
    public func export(to destination: URL, format: ExportFormat) throws {
        let entries: [Entry] = queue.sync {
            let decoder = Self.makeDecoder()
            let files = (1 ... Self.rotatedFilesKept).reversed().map(rotatedURL) + [logURL]
            return files.flatMap { tailLines(of: $0, limit: .max) }
                .compactMap { try? decoder.decode(Entry.self, from: $0) }
        }
        switch format {
        case .jsonl:
            var data = Data()
            for entry in entries {
                try data.append(encoder.encode(entry))
                data.append(0x0A)
            }
            try data.write(to: destination, options: .atomic)
        case .csv:
            let formatter = ISO8601DateFormatter()
            var text = "timestamp,action,outcome,mode,dryRun,sizeBytes,path,trashedPath,detail,sessionID\n"
            for entry in entries {
                let fields = [
                    formatter.string(from: entry.timestamp), entry.action, entry.outcome.rawValue,
                    entry.mode.rawValue, String(entry.dryRun), String(entry.sizeBytes),
                    entry.path, entry.trashedPath ?? "", entry.detail ?? "", entry.sessionID?.uuidString ?? "",
                ]
                text += fields.map(Self.csvEscape).joined(separator: ",") + "\n"
            }
            try Data(text.utf8).write(to: destination, options: .atomic)
        }
    }

    /// Clears the log, its rotated files and the running totals. Does nothing
    /// while an administrator policy forces logging on.
    public func clear() {
        if persistsEnabled, ManagedPolicy.shared.forceOperationLog {
            return
        }
        queue.sync {
            let fm = FileManager.default
            try? fm.removeItem(at: logURL)
            try? fm.removeItem(at: totalsURL)
            for index in 1 ... Self.rotatedFilesKept {
                try? fm.removeItem(at: rotatedURL(index))
            }
            lastLineHash = nil
            lastLineHashLoaded = true
        }
    }

    // MARK: - Helpers

    /// Reads the totals sidecar. When there isn't one yet (a log written by an
    /// earlier version) it is rebuilt from the entries still on disk;
    /// `excludingLastLine` leaves out the line `write` has just appended and
    /// is about to count itself.
    private func storedTotals() -> Totals? {
        guard let data = try? Data(contentsOf: totalsURL) else { return nil }
        return try? JSONDecoder().decode(Totals.self, from: data)
    }

    private func loadTotals(excludingLastLine: Bool) -> Totals {
        if let totals = storedTotals() {
            return totals
        }
        let decoder = Self.makeDecoder()
        let files = (1 ... Self.rotatedFilesKept).reversed().map(rotatedURL) + [logURL]
        var lines = files.flatMap { tailLines(of: $0, limit: .max) }
        if excludingLastLine, !lines.isEmpty {
            lines.removeLast()
        }
        var totals = Totals()
        for line in lines {
            guard let entry = try? decoder.decode(Entry.self, from: line) else { continue }
            totals.record(entry)
        }
        return totals
    }

    private func saveTotals(_ totals: Totals) {
        guard let data = try? JSONEncoder().encode(totals) else { return }
        try? data.write(to: totalsURL, options: .atomic)
    }

    /// The last `limit` non-empty lines of `url`, oldest first, read from the
    /// end of the file so a short tail never costs a full-file read.
    private func tailLines(of url: URL, limit: Int) -> [Data] {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return [] }

        let chunkSize: UInt64 = 64 * 1024
        var offset = fileSize
        // Chunks newest first, joined once at the end: prepending each chunk
        // to one buffer recopies everything read so far, every time.
        var chunks: [Data] = []
        var newlines = 0
        while offset > 0 {
            let readSize = min(chunkSize, offset)
            offset -= readSize
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(readSize)) else { break }
            newlines += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            chunks.append(chunk)
            // Two spare newlines: one may be the terminator of a line that
            // lies before the buffer, and the oldest fragment may be partial.
            if limit != .max, newlines > limit + 1 {
                break
            }
        }
        var buffer = Data(capacity: Int(fileSize - offset))
        for chunk in chunks.reversed() {
            buffer.append(chunk)
        }
        var lines = buffer.split(separator: 0x0A).map { Data($0) }
        // If the read stopped mid-file, the first fragment is partial —
        // unless the buffer happens to begin exactly on a line boundary.
        if offset > 0, buffer.first != 0x0A, !lines.isEmpty {
            lines.removeFirst()
        }
        return limit == .max ? lines : Array(lines.suffix(limit))
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func hash(_ line: Data) -> String {
        SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
    }

    /// Quotes a field for CSV. A field that a spreadsheet would read as a
    /// formula (a file name starting with `=`, `+`, `-`, `@` or a tab) is
    /// prefixed with an apostrophe so opening the export can't run it.
    public static func csvEscape(_ field: String) -> String {
        var field = field
        if let first = field.first, "=+-@\t\r".contains(first) {
            field = "'" + field
        }
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "'" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
