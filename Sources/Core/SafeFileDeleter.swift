import Foundation

/// The single deletion funnel. Every feature routes deletions through here.
/// Mirrors Mole's `mole_delete` from `lib/core/file_ops.sh`.
///
/// Two phases:
/// 1. `preview(targets)` -> `Plan` (no mutation, returns what *would* be removed)
/// 2. `execute(plan, mode:)` performs the actual deletion (Trash or permanent)
///
/// Guarantees:
/// - Trash routing by default (Finder-recoverable)
/// - Operation log entries for every action
/// - Dry-run support (no mutation, logged as dryRun)
/// - Protected-path check via `PathProtection`
public final class SafeFileDeleter {
    public static let shared = SafeFileDeleter()

    private let fileManager: FileManager
    private let protection: PathProtection
    private let opLog: OperationLog

    public init(
        fileManager: FileManager = .default,
        protection: PathProtection = .shared,
        opLog: OperationLog = .shared
    ) {
        self.fileManager = fileManager
        self.protection = protection
        self.opLog = opLog
    }

    public enum Mode: String, Codable {
        case trash       // Route to Finder Trash (recoverable)
        case permanent   // Direct removal (non-recoverable) — use sparingly
    }

    public enum Category: String, Codable {
        case cache
        case log
        case trash
        case leftover
        case artifact
        case app
        case installer
        case duplicate
        case largeFile
    }

    /// A single item to be deleted.
    public struct Item: Identifiable, Hashable {
        public let id: String        // absolute path
        public let url: URL
        public let sizeBytes: Int64
        public let category: Category
        public let protected: Bool   // true if PathProtection says do not touch

        public init(url: URL, sizeBytes: Int64, category: Category) {
            self.url = url
            self.id = url.path
            self.sizeBytes = sizeBytes
            self.category = category
            self.protected = PathProtection.shared.shouldProtect(url)
        }

        public init(url: URL, sizeBytes: Int64, category: Category, protected: Bool) {
            self.url = url
            self.id = url.path
            self.sizeBytes = sizeBytes
            self.category = category
            self.protected = protected
        }
    }

    /// A plan built from preview — what will be removed and what is skipped.
    public struct Plan: Identifiable {
        public let id = UUID()
        public let items: [Item]
        public let protectedItems: [Item]
        public let missingItems: [Item]
        public let totalReclaimable: Int64

        public init(items: [Item], protectedItems: [Item], missingItems: [Item]) {
            self.items = items
            self.protectedItems = protectedItems
            self.missingItems = missingItems
            self.totalReclaimable = items.reduce(0) { $0 + $1.sizeBytes }
        }

        public var isEmpty: Bool {
            items.isEmpty && protectedItems.isEmpty && missingItems.isEmpty
        }
    }

    /// Result of executing a plan.
    public struct ExecutionResult {
        public let freedBytes: Int64
        public let succeeded: Int
        public let failed: Int
        public let skipped: Int
        public let errors: [String]

        public init(freedBytes: Int64, succeeded: Int, failed: Int, skipped: Int, errors: [String]) {
            self.freedBytes = freedBytes
            self.succeeded = succeeded
            self.failed = failed
            self.skipped = skipped
            self.errors = errors
        }
    }

    /// Phase 1: Build a plan from candidate targets. No mutation occurs.
    /// Protected paths and missing files are separated out (never deleted).
    public func preview(_ targets: [URL], category: Category) -> Plan {
        var items: [Item] = []
        var protectedItems: [Item] = []
        var missingItems: [Item] = []

        for url in targets {
            if protection.shouldProtect(url) {
                protectedItems.append(Item(url: url, sizeBytes: 0, category: category, protected: true))
                continue
            }
            guard fileManager.fileExists(atPath: url.path) else {
                missingItems.append(Item(url: url, sizeBytes: 0, category: category, protected: false))
                continue
            }
            let size = directorySize(url)
            items.append(Item(url: url, sizeBytes: size, category: category))
        }

        return Plan(items: items, protectedItems: protectedItems, missingItems: missingItems)
    }

    /// Phase 2: Execute a plan. In dry-run mode, no files are touched.
    public func execute(_ plan: Plan, mode: Mode, dryRun: Bool, action: String) -> ExecutionResult {
        var freed: Int64 = 0
        var succeeded = 0
        var failed = 0
        var skipped = 0
        var errors: [String] = []

        for item in plan.items {
            if dryRun {
                opLog.append(.init(
                    action: action, path: item.url.path,
                    sizeBytes: item.sizeBytes, mode: .init(mode),
                    outcome: .dryRun, dryRun: true
                ))
                freed += item.sizeBytes
                succeeded += 1
                continue
            }

            do {
                if mode == .trash {
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                } else {
                    try fileManager.removeItem(at: item.url)
                }
                opLog.append(.init(
                    action: action, path: item.url.path,
                    sizeBytes: item.sizeBytes, mode: .init(mode),
                    outcome: .success, dryRun: false
                ))
                freed += item.sizeBytes
                succeeded += 1
            } catch {
                opLog.append(.init(
                    action: action, path: item.url.path,
                    sizeBytes: item.sizeBytes, mode: .init(mode),
                    outcome: .failed, dryRun: false, detail: error.localizedDescription
                ))
                failed += 1
                errors.append("\(item.url.path): \(error.localizedDescription)")
            }
        }

        for item in plan.protectedItems {
            opLog.append(.init(
                action: action, path: item.url.path,
                sizeBytes: 0, mode: .init(mode),
                outcome: .skipped, dryRun: dryRun, detail: "Protected path"
            ))
            skipped += 1
        }

        return ExecutionResult(
            freedBytes: freed, succeeded: succeeded,
            failed: failed, skipped: skipped, errors: errors
        )
    }

    /// Measures the total size of a file or directory (recursive).
    public func directorySize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        // Single file — return its size directly (the enumerator path below
        // returns 0 for non-directories).
        if !isDir.boolValue {
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                return size
            }
            return 0
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

private extension OperationLog.Mode {
    init(_ mode: SafeFileDeleter.Mode) {
        switch mode {
        case .trash: self = .trash
        case .permanent: self = .permanent
        }
    }
}