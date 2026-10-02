import Darwin
import Foundation

/// The one place the app spawns a subprocess.
///
/// Both pipes are drained concurrently while the process runs, so a child that
/// writes more than a pipe buffer's worth of output can't deadlock against a
/// `waitUntilExit()` that is itself waiting for the pipe to be read. A timeout
/// terminates a child that hangs. The async entry point hops to a dispatch
/// queue, so a blocking wait never occupies a Swift-concurrency thread.
public enum ProcessRunner {
    public struct Output: Sendable, Equatable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        /// The process could not be started at all (missing binary, permissions).
        public let launchFailed: Bool
        public let timedOut: Bool

        public var succeeded: Bool { !launchFailed && !timedOut && exitCode == 0 }

        public init(exitCode: Int32, stdout: String, stderr: String, launchFailed: Bool = false, timedOut: Bool = false) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.launchFailed = launchFailed
            self.timedOut = timedOut
        }
    }

    private static let queue = DispatchQueue(label: "myKikau.process", qos: .userInitiated, attributes: .concurrent)

    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 30
    ) async -> Output {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    /// Blocking variant for callers already off the main thread.
    public static func runBlocking(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 30
    ) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.process.error("could not launch \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return Output(exitCode: -1, stdout: "", stderr: error.localizedDescription, launchFailed: true)
        }

        // Drain both pipes as data arrives, so a chatty child can't fill a
        // pipe and block.
        let outData = PipeCollector(outPipe.fileHandleForReading)
        let errData = PipeCollector(errPipe.fileHandleForReading)

        let timedOut = TimeoutFlag()
        let pid = process.processIdentifier
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            // A child that ignores SIGTERM doesn't get to ignore this.
            DispatchQueue.global().asyncAfter(deadline: .now() + terminationGrace) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        process.waitUntilExit()
        killer.cancel()
        // The child is gone, but something it started may still hold the
        // pipes open. Take what arrives within the grace period and stop.
        outData.finish(within: terminationGrace)
        errData.finish(within: terminationGrace)
        if timedOut.value {
            Log.process.error("\(executable, privacy: .public) timed out after \(timeout)s and was terminated")
        }

        return Output(
            exitCode: process.terminationStatus,
            stdout: String(data: outData.data, encoding: .utf8) ?? "",
            stderr: String(data: errData.data, encoding: .utf8) ?? "",
            timedOut: timedOut.value
        )
    }

    /// How long a terminated child gets before SIGKILL, and how long to wait
    /// for remaining pipe output after the child exits.
    static let terminationGrace: TimeInterval = 2
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// Accumulates everything written to a pipe until end-of-file, or until
/// `finish` gives up waiting for it.
private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.done.signal()
            } else {
                self.lock.lock()
                self.buffer.append(chunk)
                self.lock.unlock()
            }
        }
    }

    func finish(within grace: TimeInterval) {
        if done.wait(timeout: .now() + grace) == .timedOut {
            handle.readabilityHandler = nil
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
