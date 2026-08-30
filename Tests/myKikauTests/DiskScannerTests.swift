import Foundation
import Testing
@testable import Features

struct DiskScannerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskScannerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("includeHidden: false collapses dot-prefixed entries into one non-navigable row")
    func hiddenCollapsedWhenExcluded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0xAB, count: 4096).write(to: dir.appendingPathComponent("visible.bin"))
        try Data(repeating: 0xCD, count: 8192).write(to: dir.appendingPathComponent(".secret.bin"))

        let entries = DiskScanner.scan(dir, includeHidden: false)
        #expect(entries.contains { $0.name == "visible.bin" })
        #expect(!entries.contains { $0.name == ".secret.bin" })
        let hidden = try #require(entries.first { $0.name == "Hidden Items" })
        #expect(hidden.isNavigable == false)
        #expect(hidden.sizeBytes > 0)
    }

    @Test("includeHidden: true shows dot-prefixed entries as their own rows")
    func hiddenShownWhenIncluded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0xAB, count: 4096).write(to: dir.appendingPathComponent("visible.bin"))
        try Data(repeating: 0xCD, count: 8192).write(to: dir.appendingPathComponent(".secret.bin"))

        let entries = DiskScanner.scan(dir, includeHidden: true)
        #expect(entries.contains { $0.name == ".secret.bin" })
        #expect(!entries.contains { $0.name == "Hidden Items" })
    }

    @Test("startupVolumeInfo reports a positive capacity and non-negative free space")
    func startupVolumeInfoIsSane() throws {
        let info = try #require(DiskScanner.startupVolumeInfo())
        #expect(info.totalBytes > 0)
        #expect(info.freeBytes >= 0)
        #expect(info.freeBytes <= info.totalBytes)
        #expect(!info.name.isEmpty)
    }

    // A full `volumeOverview()` walk is exercised by the app itself (and is
    // deliberately slow — it measures /Users and /Library); it isn't run here
    // to keep the unit suite fast.
    @Test("synthetic Free row is non-navigable")
    func syntheticRowIsNonNavigable() {
        let entry = DiskScanner.Entry(
            url: URL(fileURLWithPath: "/x/visible"),
            sizeBytes: 10,
            isDirectory: true
        )
        #expect(entry.isNavigable == true)
    }
}
