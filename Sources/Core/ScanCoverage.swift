import Foundation

/// Read coverage is separate from findings: an empty result is only an all-clear
/// when every accessible location was checked successfully.
public struct ScanCoverage: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case denied, unavailable, missing }
    public struct Issue: Identifiable, Sendable, Equatable {
        public let path: String
        public let kind: Kind
        public let detail: String
        public var id: String {
            path + kind.rawValue
        }
    }

    public var checkedPaths: [String] = []
    public var issues: [Issue] = []
    public var additionalIssueCount = 0
    public var skippedCloudOnly = 0
    public var isPartial: Bool {
        additionalIssueCount > 0 || issues.contains { $0.kind != .missing }
    }

    public var unavailableCount: Int {
        issues.filter { $0.kind != .missing }.count + additionalIssueCount
    }

    public var missingCount: Int {
        issues.filter { $0.kind == .missing }.count
    }

    public init() {}
}

/// Scanners may report from concurrent child tasks; keep bounded evidence and
/// never lose the fact that an incomplete read occurred after the list fills.
public final class ScanCoverageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ScanCoverage()
    public init() {}
    public func checked(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if !value.checkedPaths.contains(url.path) {
            value.checkedPaths.append(url.path)
        }
    }

    public func cloudSkipped() {
        lock.lock(); defer { lock.unlock() }
        value.skippedCloudOnly += 1
    }

    public func failed(_ url: URL, error: Error) {
        let error = error as NSError
        let kind: ScanCoverage
            .Kind = if (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
        {
            .missing
        } else if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
            || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code))
        {
            .denied
        } else {
            .unavailable
        }
        record(url, kind: kind, detail: error.localizedDescription)
    }

    public func record(_ url: URL, kind: ScanCoverage.Kind, detail: String) {
        lock.lock(); defer { lock.unlock() }
        guard !value.issues.contains(where: { $0.path == url.path && $0.kind == kind }) else { return }
        if value.issues.count < 200 {
            value.issues.append(.init(path: url.path, kind: kind, detail: detail))
        } else if kind != .missing {
            value.additionalIssueCount += 1
        }
    }

    public var snapshot: ScanCoverage {
        lock.lock(); defer { lock.unlock() }
        var result = value
        result.checkedPaths.sort()
        result.issues.sort { $0.path < $1.path }
        return result
    }
}
