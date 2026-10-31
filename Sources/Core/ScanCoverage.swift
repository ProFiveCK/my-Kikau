import Foundation

/// Read coverage is separate from findings: an empty result is only an all-clear
/// when every accessible location was checked successfully.
public struct ScanCoverage: Sendable, Equatable {
    /// `denied` is a privacy block that Full Disk Access would lift.
    /// `restricted` can't be read by any app setting: a folder only its owner
    /// (usually root or a system daemon) may open, or one macOS seals off even
    /// with Full Disk Access (data vaults). It is reported, not a scan gap.
    public enum Kind: String, Sendable, Codable { case denied, unavailable, missing, restricted }
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
        additionalIssueCount > 0 || issues.contains(where: \.kind.isGap)
    }

    public var unavailableCount: Int {
        issues.filter(\.kind.isGap).count + additionalIssueCount
    }

    public var restrictedCount: Int {
        issues.filter { $0.kind == .restricted }.count
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
    private let fullDiskAccess: () -> Bool
    private lazy var hasFullDiskAccess = fullDiskAccess()

    /// `fullDiskAccess` is asked once, on the first "operation not permitted".
    public init(fullDiskAccess: @escaping () -> Bool = FullDiskAccessCheck.probe) {
        self.fullDiskAccess = fullDiskAccess
    }

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
        // Foundation wraps the system error: NSFileReadNoPermissionError with
        // the POSIX code underneath.
        let posix = error.domain == NSPOSIXErrorDomain
            ? error.code
            : (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        if (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || posix == Int(ENOENT)
        {
            record(url, kind: .missing, detail: error.localizedDescription)
        } else if posix == Int(EACCES) {
            // Unix permissions, never a privacy setting: privacy blocks are EPERM.
            let owner = (try? FileManager.default.attributesOfItem(atPath: url.path)[.ownerAccountName] as? String) ?? "another account"
            record(url, kind: .restricted, detail: "Readable only by its owner (\(owner)). No setting can change this.")
        } else if posix == Int(EPERM), lock.withLock({ hasFullDiskAccess }) {
            // With Full Disk Access, EPERM is a folder macOS keeps from every app.
            record(url, kind: .restricted, detail: "Protected by macOS, even with Full Disk Access.")
        } else if posix == Int(EPERM) || (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError) {
            record(url, kind: .denied, detail: error.localizedDescription)
        } else {
            record(url, kind: .unavailable, detail: error.localizedDescription)
        }
    }

    public func record(_ url: URL, kind: ScanCoverage.Kind, detail: String) {
        lock.lock(); defer { lock.unlock() }
        guard !value.issues.contains(where: { $0.path == url.path && $0.kind == kind }) else { return }
        if value.issues.count < 200 {
            value.issues.append(.init(path: url.path, kind: kind, detail: detail))
        } else if kind.isGap {
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

extension ScanCoverage.Kind {
    /// A read that left something unmeasured that the user could fix or retry.
    var isGap: Bool {
        self == .denied || self == .unavailable
    }
}
