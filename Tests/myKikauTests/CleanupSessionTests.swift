import Foundation
import Testing
@testable import Core
@testable import Features

@Suite("Cleanup sessions")
struct CleanupSessionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("One execution is one session, separate executions stay separate, and rotations retain the group")
    func groupingAcrossRotations() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let log = OperationLog(logURL: root.appendingPathComponent("operations.log"), enabled: true, persistsEnabled: false, maxFileBytes: 1)
        let deleter = SafeFileDeleter(opLog: log)
        let files = try (0..<3).map { index -> URL in
            let url = trash.appendingPathComponent("file\(index)")
            try Data("fixture".utf8).write(to: url)
            return url
        }
        _ = deleter.execute(deleter.preview(Array(files.prefix(2)), category: .trash), mode: .permanent, dryRun: false, action: "clean")
        _ = deleter.execute(deleter.preview([files[2]], category: .trash), mode: .permanent, dryRun: false, action: "clean")
        log.flush()
        let sessions = log.cleanupSessions()
        #expect(sessions.count == 2)
        #expect(sessions.map { $0.entries.count }.sorted() == [1, 2])
        #expect(Set(sessions.flatMap(\.entries).map(\.path)) == Set(files.map(\.path)))
        #expect(CleanupRecovery.preview(sessions[0], deleter: deleter).allSatisfy { !$0.isAvailable })
    }

    @Test("Recovery moves only the selected files and a second restore cannot replace them")
    func restoreSelection() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try fixture(root)
        let log = OperationLog(logURL: root.appendingPathComponent("operations.log"))
        let deleter = SafeFileDeleter(opLog: log)
        let preview = CleanupRecovery.preview(session, deleter: deleter)
        #expect(preview.allSatisfy { $0.isAvailable })
        let results = await CleanupRecovery.restore([preview[0]], deleter: deleter)
        #expect(results.count == 1)
        #expect(results[0].restored)
        #expect(FileManager.default.fileExists(atPath: session.entries[0].path))
        #expect(!FileManager.default.fileExists(atPath: session.entries[1].path))
        let again = await CleanupRecovery.restore([preview[0]], deleter: deleter)
        #expect(again.first?.restored == false)
        #expect(log.recent().first?.sessionID == session.id)
        #expect(log.totals().trashedBytes == 0)
    }

    @Test("Changed destinations are rechecked after preview and never overwritten")
    func destinationConflict() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try fixture(root)
        let preview = CleanupRecovery.preview(session)
        let original = URL(fileURLWithPath: session.entries[0].path)
        try Data("new content".utf8).write(to: original)
        #expect(CleanupRecovery.preview(session)[0].unavailableReason == SafeFileDeleter.PutBackError.originalLocationOccupied.localizedDescription)
        let result = await CleanupRecovery.restore([preview[0]])
        #expect(result.first?.restored == false)
        #expect(try String(contentsOf: original, encoding: .utf8) == "new content")
    }

    @Test("No new sessions are stored with logging disabled; old entries still decode")
    func compatibilityAndOptOut() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = OperationLog(logURL: root.appendingPathComponent("operations.log"), enabled: false)
        log.append(try fixture(root).entries[0])
        #expect(log.cleanupSessions().isEmpty)
        let json = """
        {"timestamp":"2026-01-01T00:00:00Z","action":"clean","path":"/tmp/a","sizeBytes":1,"mode":"trash","outcome":"success","dryRun":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(OperationLog.Entry.self, from: Data(json.utf8)).sessionID == nil)
    }

    private func fixture(_ root: URL) throws -> CleanupSession {
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let id = UUID()
        let entries = try (0..<2).map { index -> OperationLog.Entry in
            let source = trash.appendingPathComponent("old\(index)")
            try Data("fixture".utf8).write(to: source)
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let number = try #require(attributes[.systemFileNumber] as? NSNumber)
            return .init(sessionID: id, action: "clean", path: root.appendingPathComponent("restored\(index)").path,
                         sizeBytes: 7, mode: .trash, outcome: .success, dryRun: false,
                         trashedPath: source.path, trashedFileNumber: number.uint64Value)
        }
        return CleanupSession(id: id, entries: entries)
    }
}

@Suite("Scan modes")
struct ScanModeTests {
    @Test("Quick scans exclude deep file comparison, application sizing and subprocess maintenance")
    func scope() {
        let quick = ScanEverythingCoordinator.ScanMode.quick.phases
        #expect(quick == [.clean, .startup])
        #expect(!quick.contains(.duplicates))
        #expect(!quick.contains(.apps))
        #expect(!quick.contains(.maintenance))
        #expect(ScanEverythingCoordinator.ScanMode.full.phases == ScanEverythingCoordinator.Phase.allCases)
    }
}
