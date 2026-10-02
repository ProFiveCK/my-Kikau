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
        if ManagedPolicy.shared.disablePrivilegedTools {
            throw RunError.failed("Actions that need an administrator password are disabled by your organisation.")
        }
        // Long timeout: the clock runs while the password dialog is on screen.
        let output = await ProcessRunner.run("/usr/bin/osascript", ["-e", makeScript(for: command)], timeout: 300)
        return try result(for: output).get()
    }

    /// Builds the AppleScript one-liner, escaping `command` for a double-quoted
    /// AppleScript string literal. Exposed for testing.
    static func makeScript(for command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func result(for output: ProcessRunner.Output) -> Result<String, RunError> {
        if output.launchFailed {
            return .failure(.failed("Couldn't start the authorization prompt: \(output.stderr)"))
        }
        if output.timedOut {
            return .failure(.cancelled)
        }
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.exitCode == 0 {
            return .success(stdout)
        }
        // osascript surfaces a user-dismissed auth dialog as error -128 / "User canceled."
        if stderr.contains("-128") || stderr.localizedCaseInsensitiveContains("User canceled") {
            return .failure(.cancelled)
        }
        return .failure(.failed(stderr.isEmpty ? "Exit code \(output.exitCode)" : stderr))
    }
}
