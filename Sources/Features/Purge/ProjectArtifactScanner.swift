import Foundation
import Core

/// Scans project directories for build artifacts (node_modules, target, build, dist, .build, venv).
/// Mirrors Mole's `lib/clean/project.sh` purge discovery + `MOLE_PURGE_TARGETS`.
public enum ProjectArtifactScanner {
    /// Artifact directory names that are safe to purge.
    public static let targetNames: Set<String> = [
        "node_modules",
        "target",
        "build",
        "dist",
        ".build",
        "venv",
        ".venv",
        "__pycache__",
        ".gradle",
        "DerivedData",
        ".next",
        ".turbo",
        ".cache",
    ]

    /// Default project search paths (mirrors Mole's MOLE_PURGE_DEFAULT_SEARCH_PATHS).
    public static let defaultSearchPaths: [String] = [
        "~/Projects",
        "~/GitHub",
        "~/dev",
        "~/Developer",
        "~/code",
        "~/src",
        "~/MyProjects",
    ]

    /// A discovered artifact to potentially purge.
    public struct Artifact: Identifiable, Hashable {
        public let id: String
        public let url: URL
        public let projectName: String
        public let artifactType: String  // e.g. "node_modules"
        public let sizeBytes: Int64
        public let lastModified: Date?
        public let isRecent: Bool        // modified within 7 days

        public init(url: URL, projectName: String, artifactType: String, sizeBytes: Int64, lastModified: Date?, isRecent: Bool) {
            self.id = url.path
            self.url = url
            self.projectName = projectName
            self.artifactType = artifactType
            self.sizeBytes = sizeBytes
            self.lastModified = lastModified
            self.isRecent = isRecent
        }
    }

    /// Reads custom purge paths from config file (~/.config/myKikau/purge_paths).
    public static func configuredPaths() -> [URL] {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/myKikau")
        let configFile = configDir.appendingPathComponent("purge_paths")
        guard let content = try? String(contentsOf: configFile) else { return [] }
        return content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }

    /// Returns all search paths (configured or default).
    public static func searchPaths() -> [URL] {
        let configured = configuredPaths()
        if !configured.isEmpty { return configured }
        return defaultSearchPaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
        }
    }

    /// Scans search paths for purgeable artifacts.
    public static func scan(deleter: SafeFileDeleter = .shared) -> [Artifact] {
        var results: [Artifact] = []
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 86400)
        let fm = FileManager.default

        for searchPath in searchPaths() {
            guard fm.fileExists(atPath: searchPath.path) else { continue }
            guard let projects = try? fm.contentsOfDirectory(
                at: searchPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for project in projects {
                let isDir = (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let projectName = project.lastPathComponent

                guard let contents = try? fm.contentsOfDirectory(
                    at: project,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for entry in contents where targetNames.contains(entry.lastPathComponent) {
                    let size = deleter.directorySize(entry)
                    let modDate = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    let isRecent = (modDate ?? Date.distantPast) > sevenDaysAgo
                    results.append(Artifact(
                        url: entry, projectName: projectName,
                        artifactType: entry.lastPathComponent,
                        sizeBytes: size, lastModified: modDate, isRecent: isRecent
                    ))
                }
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Builds a deletion plan from selected artifacts.
    public static func plan(for artifacts: [Artifact], deleter: SafeFileDeleter = .shared) -> SafeFileDeleter.Plan {
        deleter.preview(artifacts.map { $0.url }, category: .artifact)
    }
}