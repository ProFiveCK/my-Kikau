import Foundation
import os

/// Diagnostic logging through the unified logging system. View it with
/// Console.app, or:
///
///     log show --last 1h --predicate 'subsystem == "com.profiveck.myKikau"'
///
/// This is for troubleshooting. The record of what was removed — the audit
/// trail — is `OperationLog`. File paths are logged as private, so they are
/// redacted unless private-data logging is enabled on the Mac.
public enum Log {
    public static let subsystem = "com.profiveck.myKikau"

    public static let deletion = Logger(subsystem: subsystem, category: "deletion")
    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let process = Logger(subsystem: subsystem, category: "process")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
