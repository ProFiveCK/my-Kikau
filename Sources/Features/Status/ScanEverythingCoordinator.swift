import Foundation
import Core

/// Backs the Status dashboard's "Scan Everything" action.
///
/// Runs the Clean scan and caches the result, so:
/// - Status can show one combined "X items · Y GB reclaimable" number instead
///   of making the user run the scan separately (the single biggest UX gap
///   vs. CleanMyMac's Smart Care — see docs/MODERNIZATION_REVIEW.md).
/// - Navigating from Status into Clean afterwards doesn't force a redundant
///   re-scan — Clean adopts the cached result if it hasn't scanned on its
///   own yet.
///
/// Deliberately does *not* fold in Uninstall (per-app, user-directed, not a
/// "what can I reclaim right now" scan) or Analyze (browse-only, produces no
/// deletion plan / reclaimable total).
///
/// Purge scanning is still wired up here (`purgeArtifacts`) but not triggered
/// from `scanEverything()` — Purge itself is pulled from this release (too
/// developer-specific to expose without more explanation than the dashboard
/// card has room for). Re-enable by adding the `ProjectArtifactScanner.scan()`
/// call back into `scanEverything()` alongside Clean.
@MainActor
public final class ScanEverythingCoordinator: ObservableObject {
    public static let shared = ScanEverythingCoordinator()

    @Published public private(set) var isScanning = false
    @Published public private(set) var cleanPlans: [CleanScanner.Section: SafeFileDeleter.Plan]?
    @Published public private(set) var purgeArtifacts: [ProjectArtifactScanner.Artifact]?
    @Published public private(set) var lastScanAt: Date?

    private init() {}

    public var hasResults: Bool { cleanPlans != nil || purgeArtifacts != nil }

    public var combinedReclaimableBytes: Int64 {
        let cleanTotal = cleanPlans?.values.reduce(Int64(0)) { $0 + $1.totalReclaimable } ?? 0
        let purgeTotal = purgeArtifacts?.reduce(Int64(0)) { $0 + $1.sizeBytes } ?? 0
        return cleanTotal + purgeTotal
    }

    public var combinedItemCount: Int {
        let cleanCount = cleanPlans?.values.reduce(0) { $0 + $1.items.count } ?? 0
        let purgeCount = purgeArtifacts?.count ?? 0
        return cleanCount + purgeCount
    }

    public func scanEverything() async {
        isScanning = true
        cleanPlans = await Task.detached(priority: .userInitiated) { CleanScanner.scanAll() }.value
        lastScanAt = Date()
        isScanning = false
    }
}
