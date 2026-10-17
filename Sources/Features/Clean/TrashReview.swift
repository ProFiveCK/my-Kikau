import Foundation
import Core

/// Menu-bar entry point: prepare evidence for the main window's review.
/// This never executes a plan; permanent deletion remains behind the shared
/// review sheet's exact selection and second confirmation.
public struct TrashReview: Sendable {
    public let plan: SafeFileDeleter.Plan
    public let coverage: ScanCoverage

    public static func prepare(home: URL? = nil, deleter: SafeFileDeleter = .shared) -> TrashReview {
        let coverage = ScanCoverageRecorder()
        let plan = CleanScanner.scan(.trash, deleter: deleter, home: home, coverage: coverage)
        return TrashReview(plan: plan, coverage: coverage.snapshot)
    }
}
