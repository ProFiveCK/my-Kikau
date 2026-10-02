import Foundation

/// The single deletion funnel. Every feature routes deletions through here.
///
/// Two phases:
/// 1. `preview(targets)` -> `Plan` (no mutation, returns what *would* be removed)
/// 2. `execute(plan, mode:)` performs the actual deletion (Trash or permanent)
///
/// Guarantees:
/// - Trash routing by default (Finder-recoverable)
/// - Operation log entries for every action
/// - Dry-run support (no mutation, logged as dryRun)
/// - Protected-path check via `PathProtection`, at preview *and* again at
///   execution — a plan is never trusted to have been built correctly
/// - Permanent removal only for items that are physically inside a Trash folder
public final class SafeFileDeleter: @unchecked Sendable {
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

    public enum Mode: String, Codable, Sendable {
        case trash // Route to Finder Trash (recoverable)
        case permanent // Direct removal (non-recoverable) — only honoured inside a Trash folder
    }

    public enum Category: String, Codable, Sendable {
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
    public struct Item: Identifiable, Hashable, Sendable {
        public let id: String // absolute path
        public let url: URL
        public let sizeBytes: Int64
        public let category: Category
        public let protected: Bool // true if PathProtection says do not touch

        public init(url: URL, sizeBytes: Int64, category: Category) {
            self.url = url
            id = url.path
            self.sizeBytes = sizeBytes
            self.category = category
            protected = PathProtection.shared.shouldProtect(url)
        }

        public init(url: URL, sizeBytes: Int64, category: Category, protected: Bool) {
            self.url = url
            id = url.path
            self.sizeBytes = sizeBytes
            self.category = category
            self.protected = protected
        }

        /// True when executing this item removes it for good rather than
        /// moving it to the Trash.
        public var isPermanentRemoval: Bool {
            category == .trash && SafeFileDeleter.isInsideTrash(url)
        }
    }

    /// A plan built from preview — what will be removed and what is skipped.
    public struct Plan: Identifiable, Sendable {
        public let id = UUID()
        public let items: [Item]
        public let protectedItems: [Item]
        public let missingItems: [Item]
        public let totalReclaimable: Int64

        public init(items: [Item], protectedItems: [Item], missingItems: [Item]) {
            self.items = items
            self.protectedItems = protectedItems
            self.missingItems = missingItems
            totalReclaimable = items.reduce(0) { $0 + $1.sizeBytes }
        }

        public static let empty = Plan(items: [], protectedItems: [], missingItems: [])

        public var isEmpty: Bool {
            items.isEmpty && protectedItems.isEmpty && missingItems.isEmpty
        }

        /// The same plan restricted to the items the user left ticked.
        public func keeping(_ selectedIDs: Set<String>) -> Plan {
            Plan(
                items: items.filter { selectedIDs.contains($0.id) },
                protectedItems: protectedItems,
                missingItems: missingItems
            )
        }

        /// The plan minus items that were removed, for refreshing a list after
        /// a partial run.
        public func removing(_ removedIDs: Set<String>) -> Plan {
            Plan(
                items: items.filter { !removedIDs.contains($0.id) },
                protectedItems: protectedItems,
                missingItems: missingItems
            )
        }

        public static func merged(_ plans: [Plan]) -> Plan {
            var seen = Set<String>()
            return Plan(
                items: plans.flatMap(\.items).filter { seen.insert($0.id).inserted },
                protectedItems: plans.flatMap(\.protectedItems),
                missingItems: plans.flatMap(\.missingItems)
            )
        }
    }

    /// One item that could not be removed, with a reason a person can act on.
    public struct Failure: Identifiable, Hashable, Sendable {
        public var id: String {
            path
        }

        public let path: String
        public let reason: String
        /// The item is owned by another user (usually root) — removing it
        /// needs administrator rights myKikau doesn't have.
        public let needsAdministrator: Bool
    }

    /// Result of executing a plan.
    public struct ExecutionResult: Sendable {
        public let freedBytes: Int64
        public let succeeded: Int
        public let failed: Int
        public let skipped: Int
        public let errors: [String]
        public let failures: [Failure]
        /// IDs (paths) of the items that were actually removed.
        public let removedIDs: Set<String>
        /// Number of removed items that went to the Trash and can be put back.
        public let recoverable: Int
        public let cancelled: Bool
        public let dryRun: Bool

        public init(
            freedBytes: Int64, succeeded: Int, failed: Int, skipped: Int, errors: [String],
            failures: [Failure] = [], removedIDs: Set<String> = [], recoverable: Int = 0,
            cancelled: Bool = false, dryRun: Bool = false
        ) {
            self.freedBytes = freedBytes
            self.succeeded = succeeded
            self.failed = failed
            self.skipped = skipped
            self.errors = errors
            self.failures = failures
            self.removedIDs = removedIDs
            self.recoverable = recoverable
            self.cancelled = cancelled
            self.dryRun = dryRun
        }
    }

    /// Progress callback payload: items handled so far, total, and the item in hand.
    public struct Progress: Sendable {
        public let completed: Int
        public let total: Int
        public let currentPath: String
    }

    /// Phase 1: Build a plan from candidate targets. No mutation occurs.
    /// Protected paths and missing files are separated out (never deleted).
    public func preview(_ targets: [URL], category: Category) -> Plan {
        var items: [Item] = []
        var protectedItems: [Item] = []
        var missingItems: [Item] = []
        var seen = Set<String>()

        for url in targets where seen.insert(url.path).inserted {
            if Task.isCancelled {
                break
            }
            // The second check looks a couple of levels inside the folder for
            // a security agent's files — removing the folder would take them too.
            if protection.shouldProtect(url) || protection.containsEndpointSecurityItem(url, fileManager: fileManager) {
                protectedItems.append(Item(url: url, sizeBytes: 0, category: category, protected: true))
                continue
            }
            guard fileManager.fileExists(atPath: url.path) else {
                missingItems.append(Item(url: url, sizeBytes: 0, category: category, protected: false))
                continue
            }
            let size = directorySize(url)
            items.append(Item(url: url, sizeBytes: size, category: category, protected: false))
        }

        return Plan(items: items, protectedItems: protectedItems, missingItems: missingItems)
    }

    /// Phase 2: Execute a plan. In dry-run mode, no files are touched.
    ///
    /// Blocking — call `executeAsync` from UI code.
    public func execute(
        _ plan: Plan,
        mode: Mode,
        dryRun: Bool,
        action: String,
        progress: ((Progress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> ExecutionResult {
        var freed: Int64 = 0
        var succeeded = 0
        var failed = 0
        var skipped = 0
        var errors: [String] = []
        var failures: [Failure] = []
        var removedIDs = Set<String>()
        var recoverable = 0
        var cancelled = false

        for (index, item) in plan.items.enumerated() {
            if isCancelled() {
                cancelled = true
                break
            }
            progress?(Progress(completed: index, total: plan.items.count, currentPath: item.url.path))

            // Never trust the plan: it may be stale, or may have been built by
            // a caller that passed `protected: false`. Re-check right here.
            if protection.shouldProtect(item.url) {
                opLog.append(.init(
                    action: action, path: item.url.path,
                    sizeBytes: 0, mode: .init(mode),
                    outcome: .skipped, dryRun: dryRun, detail: "Protected path"
                ))
                skipped += 1
                continue
            }

            // Permanent removal is reserved for things that are already in a
            // Trash folder — "move something that's in the Trash to the Trash"
            // isn't a real operation, so emptying the Trash has to remove.
            // Everything else goes to the Trash no matter what was requested.
            let effectiveMode: Mode = Self.isInsideTrash(item.url)
                && (item.category == .trash || mode == .permanent) ? .permanent : .trash

            if dryRun {
                opLog.append(.init(
                    action: action, path: item.url.path,
                    sizeBytes: item.sizeBytes, mode: .init(effectiveMode),
                    outcome: .dryRun, dryRun: true
                ))
                freed += item.sizeBytes
                succeeded += 1
                continue
            }

            do {
                var trashedPath: String?
                var trashedFileNumber: UInt64?
                if effectiveMode == .trash {
                    var resulting: NSURL?
                    try fileManager.trashItem(at: item.url, resultingItemURL: &resulting)
                    trashedPath = resulting?.path
                    trashedFileNumber = trashedPath.flatMap(fileNumber(atPath:))
                    recoverable += 1
                } else {
                    try fileManager.removeItem(at: item.url)
                }
                opLog.append(.init(
                    action: action, path: item.url.path,
                    sizeBytes: item.sizeBytes, mode: .init(effectiveMode),
                    outcome: .success, dryRun: false,
                    trashedPath: trashedPath, trashedFileNumber: trashedFileNumber
                ))
                freed += item.sizeBytes
                succeeded += 1
                removedIDs.insert(item.id)
            } catch {
                let failure = Self.failure(for: item.url, error: error, fileManager: fileManager)
                opLog.append(.init(
                    action: action, path: item.url.path,
                    sizeBytes: item.sizeBytes, mode: .init(effectiveMode),
                    outcome: .failed, dryRun: false, detail: failure.reason
                ))
                failed += 1
                failures.append(failure)
                Log.deletion.error("\(action, privacy: .public): could not remove \(item.url.path, privacy: .private): \(failure.reason, privacy: .public)")
                errors.append("\(item.url.path): \(failure.reason)")
            }
        }
        progress?(Progress(completed: plan.items.count, total: plan.items.count, currentPath: ""))

        for item in plan.protectedItems {
            opLog.append(.init(
                action: action, path: item.url.path,
                sizeBytes: 0, mode: .init(mode),
                outcome: .skipped, dryRun: dryRun, detail: "Protected path"
            ))
            skipped += 1
        }

        let flags = (dryRun ? " (simulated)" : "") + (cancelled ? " (cancelled)" : "")
        Log.deletion.info(
            "\(action, privacy: .public): \(succeeded) removed, \(failed) failed, \(skipped) skipped, \(freed) bytes\(flags, privacy: .public)"
        )

        return ExecutionResult(
            freedBytes: freed, succeeded: succeeded,
            failed: failed, skipped: skipped, errors: errors,
            failures: failures, removedIDs: removedIDs, recoverable: recoverable,
            cancelled: cancelled, dryRun: dryRun
        )
    }

    /// `execute`, off the calling actor. Honours task cancellation between
    /// items and reports progress (on a background thread).
    public func executeAsync(
        _ plan: Plan,
        mode: Mode,
        dryRun: Bool,
        action: String,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> ExecutionResult {
        let task = Task.detached(priority: .userInitiated) { [self] in
            execute(plan, mode: mode, dryRun: dryRun, action: action, progress: progress, isCancelled: { Task.isCancelled })
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Moves a trashed item back to where it came from ("Put Back").
    /// Refuses to overwrite anything that now exists at the original path.
    ///
    /// - Parameter fileNumber: the item's file number recorded when it was
    ///   trashed. When given, the item now at `trashedPath` must be that same
    ///   item — not something else that was trashed under the same name later.
    public func putBack(trashedPath: String, originalPath: String, fileNumber expected: UInt64? = nil) throws {
        let trashed = URL(fileURLWithPath: trashedPath)
        let original = URL(fileURLWithPath: originalPath)
        guard Self.isInsideTrash(trashed), fileManager.fileExists(atPath: trashed.path) else {
            throw PutBackError.noLongerInTrash
        }
        if let expected, fileNumber(atPath: trashed.path) != expected {
            throw PutBackError.noLongerInTrash
        }
        guard !fileManager.fileExists(atPath: original.path) else {
            throw PutBackError.originalLocationOccupied
        }
        try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: trashed, to: original)
        opLog.append(.init(
            action: "putBack", path: original.path,
            sizeBytes: 0, mode: .trash, outcome: .success, dryRun: false
        ))
    }

    public enum PutBackError: LocalizedError {
        case noLongerInTrash
        case originalLocationOccupied

        public var errorDescription: String? {
            switch self {
            case .noLongerInTrash: "This item is no longer in the Trash."
            case .originalLocationOccupied: "Something else now exists at the original location."
            }
        }
    }

    /// Whether Put Back can still restore the item an entry describes.
    public func canPutBack(trashedPath: String, originalPath: String, fileNumber expected: UInt64? = nil) -> Bool {
        guard fileManager.fileExists(atPath: trashedPath), !fileManager.fileExists(atPath: originalPath) else {
            return false
        }
        if let expected {
            return fileNumber(atPath: trashedPath) == expected
        }
        return true
    }

    private func fileNumber(atPath path: String) -> UInt64? {
        ((try? fileManager.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// True if `url` is inside a Trash folder (`~/.Trash`, or a volume's `.Trashes`).
    public static func isInsideTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.deletingLastPathComponent().pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    private static func failure(for url: URL, error: Error, fileManager: FileManager) -> Failure {
        let nsError = error as NSError
        let permissionCodes = [NSFileWriteNoPermissionError, NSFileReadNoPermissionError]
        let posixDenied = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            $0.domain == NSPOSIXErrorDomain && ($0.code == Int(EACCES) || $0.code == Int(EPERM))
        } ?? false
        if (nsError.domain == NSCocoaErrorDomain && permissionCodes.contains(nsError.code)) || posixDenied {
            let ownerID = (try? fileManager.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber
            if let ownerID, ownerID.uint32Value != getuid() {
                return Failure(
                    path: url.path,
                    reason: "Owned by another user (usually installed by a package or the App Store) — needs an administrator to remove.",
                    needsAdministrator: true
                )
            }
            return Failure(path: url.path, reason: "Permission denied — macOS blocked access to this item.", needsAdministrator: false)
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return Failure(path: url.path, reason: "No longer exists.", needsAdministrator: false)
        }
        return Failure(path: url.path, reason: error.localizedDescription, needsAdministrator: false)
    }

    /// Measures the total size of a file or directory (recursive), hidden
    /// files included.
    public func directorySize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        // Single file — return its size directly (the enumerator path below
        // returns 0 for non-directories).
        if !isDir.boolValue {
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value
            {
                return size
            }
            return 0
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited % 512 == 0, Task.isCancelled {
                break
            }
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true
            {
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
