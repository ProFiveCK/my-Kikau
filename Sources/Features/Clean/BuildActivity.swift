import Darwin
import Foundation

/// Conservative activity check for shared build/package caches. GUI bundle
/// IDs do not reveal builds started from Terminal, an editor or a CI runner.
enum BuildActivity {
    static let toolNames: Set<String> = [
        "xcodebuild", "xcbuild", "swift", "swiftc", "swift-build", "swift-frontend",
        "clang", "clang++", "gcc", "g++", "cc", "c++", "ld", "ld-classic", "lld",
        "make", "gmake", "ninja", "cmake", "bazel", "bazelisk", "java", "javac",
        "gradle", "gradlew", "mvn", "mvnd", "go", "rustc", "cargo", "node",
        "npm", "npx", "pnpm", "yarn", "bun", "deno", "python", "python3",
        "Python", "Python3", "pip", "pip3", "dotnet", "MSBuild", "dsymutil", "actool", "ibtool", "metal",
        "brew", "ruby",
    ]

    /// In-process and scan-only; never spawns a subprocess or runs on a metrics tick.
    /// A failed/truncated process listing is unknown, never evidence of idleness.
    static func runningToolNames() -> Set<String>? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let found = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard found > 0, Int(found) < pids.count else { return nil }
        var names = Set<String>()
        for pid in pids.prefix(Int(found)) where pid > 0 {
            if Task.isCancelled {
                return nil
            }
            var name = [CChar](repeating: 0, count: 256)
            let length = name.withUnsafeMutableBytes { buffer in
                proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            if length > 0 {
                let value = String(cString: name)
                if toolNames.contains(value) {
                    names.insert(value)
                }
            }
        }
        return names
    }
}
