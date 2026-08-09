import Testing
import Core
import Features
import Foundation

/// Integration tests for ProjectArtifactScanner against a synthetic temp HOME.
@Suite("ProjectArtifactScanner integration")
struct ProjectArtifactScannerIntegrationTests {
    private func makeHome() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func touch(_ url: URL, size: Int = 8) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: size).write(to: url)
    }

    /// Sets the content modification date on a file/directory.
    private func setModDate(_ url: URL, daysAgo: Int) {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86400)
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test("scan finds node_modules and target artifacts under a search path")
    func scanFindsArtifacts() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let proj = home.appendingPathComponent("MyProjects/myproj")
        let nm = proj.appendingPathComponent("node_modules/react/index.js")
        touch(nm, size: 200)
        let target = proj.appendingPathComponent("target/debug/myproj")
        touch(target, size: 100)

        // Mark both as old so they are not "recent".
        setModDate(proj.appendingPathComponent("node_modules"), daysAgo: 30)
        setModDate(proj.appendingPathComponent("target"), daysAgo: 30)

        let artifacts = ProjectArtifactScanner.scan(home: home)

        #expect(artifacts.count == 2)
        // Sorted by size descending.
        #expect(artifacts.first?.artifactType == "node_modules")
        #expect(artifacts.first?.sizeBytes == 200)
        #expect(artifacts.last?.artifactType == "target")
        #expect(artifacts.last?.sizeBytes == 100)
        // Both > 7 days old.
        #expect(artifacts.allSatisfy { !$0.isRecent })
    }

    @Test("scan marks artifacts modified within 7 days as recent")
    func scanMarksRecent() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let proj = home.appendingPathComponent("MyProjects/freshproj")
        touch(proj.appendingPathComponent("build/output.o"), size: 40)
        // Default touch mtime is "now", so this should be recent.
        setModDate(proj.appendingPathComponent("build"), daysAgo: 1)

        let artifacts = ProjectArtifactScanner.scan(home: home)
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.isRecent == true)
    }

    @Test("scan skips non-artifact directories")
    func scanSkipsNonArtifacts() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let proj = home.appendingPathComponent("MyProjects/cleanproj")
        touch(proj.appendingPathComponent("src/main.swift"), size: 10)
        touch(proj.appendingPathComponent("README.md"), size: 2)
        // No artifact dirs — scan should find nothing.
        let artifacts = ProjectArtifactScanner.scan(home: home)
        #expect(artifacts.isEmpty)
    }

    @Test("configuredPaths reads and parses a temp purge_paths config")
    func configuredPathsReadsConfig() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let searchA = home.appendingPathComponent("codeA")
        let searchB = home.appendingPathComponent("codeB")
        try? FileManager.default.createDirectory(at: searchA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: searchB, withIntermediateDirectories: true)

        let configDir = home.appendingPathComponent(".config/myKikau")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let config = configDir.appendingPathComponent("purge_paths")
        // Write absolute paths (configuredPaths expands ~ to the real home, so
        // absolute paths are used here for deterministic behavior).
        let configContent = """
        # myKikau purge paths
        \(searchA.path)
        \(searchB.path)
        """
        try? configContent.write(to: config, atomically: true, encoding: .utf8)

        let paths = ProjectArtifactScanner.configuredPaths(home: home)
        #expect(paths.count == 2)
        #expect(paths.map { $0.path }.contains(searchA.path))
        #expect(paths.map { $0.path }.contains(searchB.path))
    }

    @Test("searchPaths prefers configured paths over defaults")
    func searchPathsPrefersConfigured() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let custom = home.appendingPathComponent("customcode")
        try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let configDir = home.appendingPathComponent(".config/myKikau")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? custom.path.write(
            to: configDir.appendingPathComponent("purge_paths"),
            atomically: true, encoding: .utf8)

        let paths = ProjectArtifactScanner.searchPaths(home: home)
        #expect(paths.map { $0.path } == [custom.path])
    }

    @Test("searchPaths falls back to defaults when no config")
    func searchPathsDefaultsWhenNoConfig() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = ProjectArtifactScanner.searchPaths(home: home)
        // Default search paths are fixed and non-empty.
        #expect(paths.count == ProjectArtifactScanner.defaultSearchPaths.count)
    }

    @Test("plan builds a deletion plan from selected artifacts")
    func planFromArtifacts() {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let proj = home.appendingPathComponent("MyProjects/planproj")
        touch(proj.appendingPathComponent("dist/bundle.js"), size: 50)
        setModDate(proj.appendingPathComponent("dist"), daysAgo: 30)

        let artifacts = ProjectArtifactScanner.scan(home: home)
        let plan = ProjectArtifactScanner.plan(for: artifacts)
        #expect(plan.items.count == 1)
        #expect(plan.items.first?.category == .artifact)
        #expect(plan.items.first?.sizeBytes == 50)
    }
}