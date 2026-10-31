import Foundation
import Testing
@testable import Core
@testable import Features

@Suite("Care foundations", .serialized)
struct CareFoundationTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Trash, permanent removal, restoration and simulation are distinct")
    func accounting() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(logURL: dir.appendingPathComponent("operations.log"))
        func append(_ action: String, _ mode: OperationLog.Mode, _ outcome: OperationLog.Outcome = .success, dry: Bool = false) {
            log.append(.init(action: action, path: "/fixture/file", sizeBytes: 100, mode: mode, outcome: outcome, dryRun: dry))
        }
        append("clean", .trash)
        append("emptyTrash", .permanent)
        append("putBack", .trash)
        append("clean", .trash, .dryRun, dry: true)
        append("clean", .permanent, .failed)
        let totals = log.totals()
        #expect(totals.trashedBytes == 100)
        #expect(totals.freedBytes == 100)
        #expect(totals.operations == 5)
    }

    @Test("Legacy mixed totals retain their value without claiming freed space")
    func legacyTotals() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("operations.log")
        try Data(#"{"freedBytes":9000,"operations":12}"#.utf8).write(to: url.deletingPathExtension().appendingPathExtension("totals.json"))
        let log = OperationLog(logURL: url)
        #expect(log.totals().freedBytes == 0)
        #expect(log.totals().trashedBytes == 0)
        #expect(log.totals().legacyProcessedBytes == 9000)
        log.append(.init(action: "clean", path: "/fixture/file", sizeBytes: 50, mode: .trash, outcome: .success, dryRun: false))
        #expect(log.totals().trashedBytes == 50)
        #expect(log.totals().legacyProcessedBytes == 9000)
        #expect(log.totals().operations == 13)
    }

    @Test("Failed and unavailable checks are never an all-clear")
    func maintenanceStates() {
        #expect(MaintenanceOutcome.recommended().needsAction)
        #expect(!MaintenanceOutcome.recommended().isClear)
        for outcome in [MaintenanceOutcome.failed(), .unavailable(), .skipped()] {
            #expect(outcome.isIncomplete)
            #expect(!outcome.isClear)
            #expect(!outcome.needsAction)
        }
        #expect(MaintenanceOutcome.unchanged().isClear)
        #expect(!MaintenanceOutcome.information().needsAction)
    }

    @Test("Unavailable reads are distinct from absent optional locations")
    func coverageClassification() {
        let c = ScanCoverageRecorder(fullDiskAccess: { false }), url = URL(fileURLWithPath: "/fixture")
        c.failed(url, error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError))
        #expect(!c.snapshot.isPartial)
        c.failed(url.appendingPathComponent("denied"), error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)))
        c.failed(url.appendingPathComponent("disk"), error: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        c.cloudSkipped()
        #expect(c.snapshot.isPartial)
        #expect(c.snapshot.unavailableCount == 2)
        #expect(c.snapshot.missingCount == 1)
        #expect(c.snapshot.skippedCloudOnly == 1)
    }

    /// Foundation's own error for a folder read, as the scanners see it.
    private func folderReadError(_ posix: Int32) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(posix)),
        ])
    }

    @Test("Owner-only and macOS-sealed folders aren't a partial scan; a privacy block without Full Disk Access is")
    func restrictedIsNotAGap() {
        let url = URL(fileURLWithPath: "/fixture")
        let withAccess = ScanCoverageRecorder(fullDiskAccess: { true })
        withAccess.failed(url.appendingPathComponent("root-only"), error: folderReadError(EACCES))
        withAccess.failed(url.appendingPathComponent("datavault"), error: folderReadError(EPERM))
        #expect(!withAccess.snapshot.isPartial)
        #expect(withAccess.snapshot.restrictedCount == 2)
        #expect(!withAccess.snapshot.issues.contains { $0.kind == .denied })

        let withoutAccess = ScanCoverageRecorder(fullDiskAccess: { false })
        withoutAccess.failed(url.appendingPathComponent("root-only"), error: folderReadError(EACCES))
        withoutAccess.failed(url.appendingPathComponent("tcc"), error: folderReadError(EPERM))
        #expect(withoutAccess.snapshot.isPartial)
        #expect(withoutAccess.snapshot.unavailableCount == 1)
        #expect(withoutAccess.snapshot.issues.contains { $0.kind == .denied && $0.path.hasSuffix("tcc") })
    }

    @Test("A real owner-only folder is reported, not counted as a read failure")
    func ownerOnlyFolderInWalk() throws {
        let dir = try folder()
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let c = ScanCoverageRecorder(fullDiskAccess: { false })
        #expect(!DiskScanner.scan(dir, coverage: c).isEmpty)
        #expect(!c.snapshot.isPartial)
        let issue = try #require(c.snapshot.issues.first)
        #expect(issue.kind == .restricted)
        #expect(issue.detail.contains(NSUserName()))
    }

    @Test("Bounded coverage evidence never drops the partial-scan state")
    func coverageBound() {
        let c = ScanCoverageRecorder()
        for n in 0..<205 { c.record(URL(fileURLWithPath: "/fixture/\(n)"), kind: .unavailable, detail: "Offline") }
        #expect(c.snapshot.issues.count == 200)
        #expect(c.snapshot.additionalIssueCount == 5)
        #expect(c.snapshot.unavailableCount == 205)
    }

    @Test("Directory enumeration failures produce coverage evidence")
    func diskReadFailure() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("file.txt")
        try Data("data".utf8).write(to: file)
        let c = ScanCoverageRecorder()
        #expect(DiskScanner.scan(file, coverage: c).isEmpty)
        #expect(c.snapshot.isPartial)
    }

    @Test("Duplicate walk records checked and missing roots")
    func fileCoverage() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = dir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: downloads.appendingPathComponent("a.txt"))
        let report = DuplicateFinder.walkReport(home: dir)
        #expect(report.files.count == 1)
        #expect(report.coverage.checkedPaths == [downloads.path])
        #expect(report.coverage.missingCount == 4)
        #expect(!report.coverage.isPartial)
    }

    @Test("Cancellation retains ownership until the worker finishes")
    @MainActor func sharedOwnership() {
        let work = WorkCoordinator()
        var cancelled = false
        let scan = work.begin("scan", cancel: { cancelled = true })!
        #expect(work.begin("delete", kind: .deletion) == nil)
        work.cancel()
        #expect(cancelled)
        #expect(work.isBusy)
        work.finish(UUID())
        #expect(work.isBusy)
        work.finish(scan)
        let deletion = work.begin("delete", kind: .deletion)!
        #expect(work.begin("scan") == nil)
        work.finish(deletion)
        #expect(!work.isBusy)
    }

    @Test("Maintenance results and user choices survive later result updates")
    @MainActor func sharedMaintenance() {
        let c = ScanEverythingCoordinator()
        c.setMaintenanceResults(["a": .init(outcome: .recommended()), "b": .init(outcome: .recommended())])
        #expect(c.hasResults)
        #expect(c.selectedMaintenanceTasks == ["a", "b"])
        c.selectedMaintenanceTasks = ["b"]
        c.setMaintenanceResults(["a": .init(outcome: .recommended()), "b": .init(outcome: .recommended())])
        #expect(c.selectedMaintenanceTasks == ["b"])
        c.setMaintenanceResults(["a": .init(outcome: .recommended()), "b": .init(outcome: .unchanged())])
        #expect(c.selectedMaintenanceTasks.isEmpty)
    }
}

@Suite("Shared scan admission", .serialized)
struct SharedScanAdmissionTests {
    @Test("A full scan cannot start while a file operation owns the activity")
    @MainActor func blocksFullScanDuringDeletion() async {
        let work = WorkCoordinator.shared
        let id = work.begin("fixture deletion", kind: .deletion)!
        defer { work.finish(id) }
        let coordinator = ScanEverythingCoordinator()
        await coordinator.scanEverything()
        #expect(!coordinator.isScanning)
        #expect(!coordinator.hasResults)
        #expect(coordinator.lastScanAt == nil)
        #expect(work.activity?.id == id)
    }
}
