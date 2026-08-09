import Testing
import Core
import Foundation

@Suite("SafeFileDeleter")
struct SafeFileDeleterTests {
    private func makeTempDir() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("Preview separates existing, protected, and missing")
    func previewCategorizes() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let existing = tmp.appendingPathComponent("cache")
        try? FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let missing = tmp.appendingPathComponent("nonexistent")

        let deleter = SafeFileDeleter()
        let plan = deleter.preview([existing, missing], category: .cache)

        #expect(plan.items.count == 1)
        #expect(plan.missingItems.count == 1)
        #expect(plan.protectedItems.isEmpty)
    }

    @Test("Preview excludes protected paths")
    func previewExcludesProtected() {
        let deleter = SafeFileDeleter()
        let plan = deleter.preview([URL(fileURLWithPath: "/System/Library")], category: .cache)
        #expect(plan.items.isEmpty)
        #expect(plan.protectedItems.count == 1)
    }

    @Test("Dry run does not delete files")
    func dryRunPreservesFiles() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("test.txt")
        try? "hello".write(to: file, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let deleter = SafeFileDeleter()
        let plan = deleter.preview([file], category: .cache)
        let result = deleter.execute(plan, mode: .trash, dryRun: true, action: "test")

        #expect(result.succeeded == 1)
        #expect(FileManager.default.fileExists(atPath: file.path) == true)
    }

    @Test("Execute via trash moves file to Trash")
    func executeMovesToTrash() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("deleteme.txt")
        try? "delete me".write(to: file, atomically: true, encoding: .utf8)

        let deleter = SafeFileDeleter()
        let plan = deleter.preview([file], category: .cache)
        let result = deleter.execute(plan, mode: .trash, dryRun: false, action: "test")

        #expect(result.succeeded == 1)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("directorySize measures file contents")
    func directorySizeMeasures() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("data.bin")
        let data = Data(count: 1024)
        try? data.write(to: file)

        let deleter = SafeFileDeleter()
        let size = deleter.directorySize(tmp)
        #expect(size == 1024)
    }
}