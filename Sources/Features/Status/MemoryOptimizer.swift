import Foundation

/// Performs a conservative memory pressure relief action.
///
/// macOS manages RAM aggressively; this does not "delete" memory or close apps.
/// It asks the system to purge inactive file caches, which can help when memory
/// pressure is high without pretending app-owned memory is cleanable junk.
public enum MemoryOptimizer {
    public static let purgePath = "/usr/bin/purge"

    public struct Result: Sendable, Hashable {
        public let succeeded: Bool
        public let message: String

        public init(succeeded: Bool, message: String) {
            self.succeeded = succeeded
            self.message = message
        }
    }

    public static func isPurgeAvailable(fileManager: FileManager = .default, path: String = purgePath) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    public static func freeInactiveMemory() async -> Result {
        guard isPurgeAvailable() else {
            return Result(
                succeeded: false,
                message: "Memory purge is not available on this macOS version. Use View Memory Users to find heavy apps."
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: purgePath)
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return Result(
                succeeded: false,
                message: "Memory purge could not start. Use View Memory Users to find heavy apps."
            )
        }

        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return Result(succeeded: true, message: "Inactive file cache purged.")
        }

        let data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        let detail = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            succeeded: false,
            message: (detail?.isEmpty == false) ? detail! : "Memory purge could not complete."
        )
    }
}
