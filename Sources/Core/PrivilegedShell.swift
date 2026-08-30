import Foundation

/// Runs a fixed shell command as root via the system Authorization Services
/// prompt — `osascript` → `do shell script … with administrator privileges`.
/// The user sees the standard macOS "myKikau wants to make changes" password
/// dialog and nothing runs unless they authenticate; macOS caches that
/// authorization for a few minutes so back-to-back actions don't re-prompt.
///
/// This is deliberately the *only* privilege-escalation path in the app. It
/// takes a caller-provided constant string — never anything derived from user
/// input, file contents, or network responses. Callers pass literals, or values
/// checked against a strict allowlist (e.g. a BSD interface name matching
/// `^[a-z]{2,}[0-9]+$`).
public enum PrivilegedShell {
    public enum RunError: Error, LocalizedError, Equatable {
        /// The user dismissed the password dialog. Nothing ran.
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "Authentication was cancelled."
            case .failed(let detail): return detail.isEmpty ? "The command could not complete." : detail
            }
        }
    }

    /// Executes `command` as root. Returns trimmed stdout on success; throws
    /// `.cancelled` if the user dismisses the prompt, `.failed` otherwise.
    public static func run(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: runBlocking(command))
            }
        }
    }

    /// Builds the AppleScript one-liner, escaping `command` for a double-quoted
    /// AppleScript string literal. Exposed for testing.
    static func makeScript(for command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    private static func runBlocking(_ command: String) -> Result<String, RunError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", makeScript(for: command)]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .failure(.failed("Couldn't start the authorization prompt: \(error.localizedDescription)"))
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            return .success(stdout)
        }
        // osascript surfaces a user-dismissed auth dialog as error -128 / "User canceled."
        if stderr.contains("-128") || stderr.localizedCaseInsensitiveContains("User canceled") {
            return .failure(.cancelled)
        }
        return .failure(.failed(stderr.isEmpty ? "Exit code \(process.terminationStatus)" : stderr))
    }
}
