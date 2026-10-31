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

        public var recoverySuggestion: String {
            if SafeFileDeleter.isInsideTrash(URL(fileURLWithPath: path)) {
                return "Open the Trash in Finder and choose Empty Trash. Finder can request administrator approval for items myKikau cannot remove."
            }
            return "Move this item to the Trash in Finder, which can request administrator approval."
        }

        public init(path: String, reason: String, needsAdministrator: Bool) {
            self.path = path
            self.reason = reason
            self.needsAdministrator = needsAdministrator
        }
    }

    /// Result of executing a plan.
    public struct ExecutionResult: Sendable {
        /// Bytes handled by this operation; Trash moves do not free disk space.
        public let freedBytes: Int64
        public let succeeded: Int
        public let failed: Int
        public let skipped: Int
        public let errors: [String]
        public let failures: [Failure]
        /// IDs (paths) of the items that were actually removed.
        public let removedIDs: Set<String>
        /// Items moved (or, in a simulation, that would move) to the Trash.
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
    public func preview(_ targets: [URL], category: Category, coverage: ScanCoverageRecorder? = nil) -> Plan {
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
            // `attributesOfItem` is an lstat: a dangling symbolic link is still
            // an item to remove, where `fileExists` would call it missing.
            do {
                _ = try fileManager.attributesOfItem(atPath: url.path)
            } catch {
                if (error as NSError).code != NSFileReadNoSuchFileError {
                    coverage?.failed(url, error: error)
                }
                missingItems.append(Item(url: url, sizeBytes: 0, category: category, protected: false))
                continue
            }
            let size = directorySize(url, coverage: coverage)
            coverage?.checked(url)
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
        sessionID: UUID = UUID(),
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
            if protection.shouldProtect(item.url) || protection.containsEndpointSecurityItem(item.url, fileManager: fileManager) {
                opLog.append(.init(
                    sessionID: sessionID, action: action, path: item.url.path,
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
                    sessionID: sessionID, action: action, path: item.url.path,
                    sizeBytes: item.sizeBytes, mode: .init(effectiveMode),
                    outcome: .dryRun, dryRun: true
                ))
                freed += item.sizeBytes
                if effectiveMode == .trash {
                    recoverable += 1
                }
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
                    do {
                        try fileManager.removeItem(at: item.url)
                    } catch where Self.unlockUserLockedItems(at: item.url) {
                        // Like Finder's Empty Trash: items the user locked
                        // (Get Info > Locked) are emptied too.
                        try fileManager.removeItem(at: item.url)
                    }
                }
                opLog.append(.init(
                    sessionID: sessionID, action: action, path: item.url.path,
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
                    sessionID: sessionID, action: action, path: item.url.path,
                    sizeBytes: item.sizeBytes, mode: .init(effectiveMode),
                    outcome: .failed, dryRun: false, detail: failure.reason
                ))
                failed += 1
                failures.append(failure)
                Log.deletion
                    .error(
                        "\(action, privacy: .public): could not remove \(item.url.path, privacy: .private): \(failure.reason, privacy: .public)"
                    )
                errors.append("\(item.url.path): \(failure.reason)")
            }
        }
        progress?(Progress(completed: plan.items.count, total: plan.items.count, currentPath: ""))

        for item in plan.protectedItems {
            opLog.append(.init(
                sessionID: sessionID, action: action, path: item.url.path,
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
    public func putBack(
        trashedPath: String, originalPath: String, fileNumber expected: UInt64? = nil, sessionID: UUID? = nil
    ) throws {
        let trashed = URL(fileURLWithPath: trashedPath)
        let original = URL(fileURLWithPath: originalPath)
        if let problem = putBackProblem(trashedPath: trashedPath, originalPath: originalPath, fileNumber: expected) {
            throw problem
        }
        try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: trashed, to: original)
        opLog.append(.init(
            sessionID: sessionID, action: "putBack", path: original.path,
            sizeBytes: 0, mode: .trash, outcome: .success, dryRun: false
        ))
    }

    public enum PutBackError: LocalizedError {
        case noLongerInTrash
        case originalLocationOccupied
        case protectedLocation

        public var errorDescription: String? {
            switch self {
            case .noLongerInTrash: "This item is no longer in the Trash."
            case .originalLocationOccupied: "Something else now exists at the original location."
            case .protectedLocation: "The original location is protected or excluded."
            }
        }
    }

    /// Whether Put Back can still restore the item an entry describes.
    public func canPutBack(trashedPath: String, originalPath: String, fileNumber expected: UInt64? = nil) -> Bool {
        putBackProblem(trashedPath: trashedPath, originalPath: originalPath, fileNumber: expected) == nil
    }

    public func putBackProblem(trashedPath: String, originalPath: String, fileNumber expected: UInt64? = nil) -> PutBackError? {
        let trashed = URL(fileURLWithPath: trashedPath)
        guard !protection.shouldProtect(URL(fileURLWithPath: originalPath)) else { return .protectedLocation }
        guard Self.isInsideTrash(trashed),
              Self.isInsideTrash(trashed.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(trashed.lastPathComponent)),
              fileManager.fileExists(atPath: trashedPath) else { return .noLongerInTrash }
        if let expected, fileNumber(atPath: trashedPath) != expected {
            return .noLongerInTrash
        }
        guard (try? fileManager.attributesOfItem(atPath: originalPath)) == nil else { return .originalLocationOccupied }
        return nil
    }

    private func fileNumber(atPath path: String) -> UInt64? {
        ((try? fileManager.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// Clears the user "Locked" flag (UF_IMMUTABLE) on `url` and everything
    /// inside it, never following links. Called only for permanent removal,
    /// which `execute` honours only inside a Trash folder. Returns true if
    /// any flag was cleared, so the caller retries. The system flag (schg)
    /// needs root and is left alone; so are items owned by another user.
    static func unlockUserLockedItems(at url: URL) -> Bool {
        guard isInsideTrash(url) else { return false }
        var unlocked = false
        func unlock(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE) != 0 else { return }
            if lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 {
                unlocked = true
            }
        }
        unlock(url.path)
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
           let walker = FileManager.default.enumerator(atPath: url.path)
        {
            while let relative = walker.nextObject() as? String {
                unlock(url.appendingPathComponent(relative).path)
            }
        }
        return unlocked
    }

    /// True if `url` is inside a Trash folder (`~/.Trash`, or a volume's `.Trashes`).
    public static func isInsideTrash(_ url: URL) -> Bool {
        // Resolve the parent, not the final component: removing a symlink in
        // the Trash removes the link itself. A symlink *posing as* a Trash
        // parent must never permit permanent deletion outside the Trash.
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        func containsTrash(_ path: URL) -> Bool {
            path.pathComponents.contains(".Trash") || path.pathComponents.contains(".Trashes")
        }
        return containsTrash(parent) && containsTrash(parent.resolvingSymlinksInPath())
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

    /// How much disk the item takes (allocated size, hidden files included).
    /// See `FileSizing`.
    public func directorySize(
        _ url: URL,
        coverage: ScanCoverageRecorder? = nil,
        shouldContinue: () -> Bool = { !Task.isCancelled }
    ) -> Int64 {
        FileSizing.allocatedSize(of: url, fileManager: fileManager, coverage: coverage, shouldContinue: shouldContinue)
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
