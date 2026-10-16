import Foundation

/// File operations from one reviewed execution. The existing local audit log
/// is the only store; disabling or clearing it also disables recovery history.
public struct CleanupSession: Identifiable, Sendable {
    public let id: UUID
    public let entries: [OperationLog.Entry]
    public var date: Date {
        entries.map(\.timestamp).min() ?? .distantPast
    }

    public var action: String {
        entries.first?.action ?? "clean"
    }

    public init(id: UUID, entries: [OperationLog.Entry]) {
        self.id = id
        self.entries = entries
    }
}

public enum CleanupRecovery {
    public struct Item: Identifiable, Sendable {
        public var id: String {
            entry.id
        }

        public let entry: OperationLog.Entry
        public let unavailableReason: String?
        public var isAvailable: Bool {
            unavailableReason == nil
        }
    }

    public struct Result: Identifiable, Sendable {
        public let id: String
        public let path: String
        public let restored: Bool
        public let message: String
    }

    /// Run off the main actor: these checks may touch an external volume.
    public static func preview(_ session: CleanupSession, deleter: SafeFileDeleter = .shared) -> [Item] {
        session.entries.map { entry in
            let reason: String? = if entry.dryRun || entry.outcome != .success {
                "This item was not removed."
            } else if entry.mode == .permanent {
                "Permanently removed — cannot be restored."
            } else if entry.trashedFileNumber == nil {
                "File identity was not recorded. Check the Trash in Finder."
            } else if let path = entry.trashedPath {
                deleter.putBackProblem(trashedPath: path, originalPath: entry.path, fileNumber: entry.trashedFileNumber)?.localizedDescription
            } else {
                "A Trash location was not recorded. Check the Trash in Finder."
            }
            return Item(entry: entry, unavailableReason: reason)
        }
    }

    /// Only the exact reviewed selection is used. Put Back rechecks protection,
    /// inode and destination immediately before each move and never overwrites.
    public static func restore(_ selection: [Item], deleter: SafeFileDeleter = .shared) async -> [Result] {
        let task = Task.detached(priority: .userInitiated) {
            var results: [Result] = []
            for item in selection where item.isAvailable {
                guard !Task.isCancelled else { break }
                let entry = item.entry
                guard let path = entry.trashedPath, let identity = entry.trashedFileNumber else { continue }
                do {
                    try deleter.putBack(trashedPath: path, originalPath: entry.path, fileNumber: identity, sessionID: entry.sessionID)
                    results.append(Result(id: item.id, path: entry.path, restored: true, message: "Restored"))
                } catch {
                    results.append(Result(id: item.id, path: entry.path, restored: false, message: error.localizedDescription))
                }
            }
            return results
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
