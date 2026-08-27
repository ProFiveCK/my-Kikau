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
    @Published public private(set) var apps: [AppInventory.AppInfo]?
    @Published public private(set) var duplicateGroups: [DuplicateFinder.DuplicateGroup]?
    @Published public private(set) var largeFiles: [DuplicateFinder.FileEntry]?
    @Published public private(set) var purgeArtifacts: [ProjectArtifactScanner.Artifact]?
    @Published public private(set) var systemHealthReport: NetworkPrivacyAuditor.Report?
    @Published public private(set) var systemHealthScanError: String?
    @Published public private(set) var lastScanAt: Date?

    private init() {}

    public var hasResults: Bool {
        cleanPlans != nil || apps != nil || duplicateGroups != nil || largeFiles != nil
            || purgeArtifacts != nil || systemHealthReport != nil || systemHealthScanError != nil
    }

    public var combinedReclaimableBytes: Int64 {
        let cleanTotal = cleanPlans?.values.reduce(Int64(0)) { $0 + $1.totalReclaimable } ?? 0
        let duplicateTotal = duplicateGroups?.reduce(Int64(0)) { $0 + $1.reclaimableBytes } ?? 0
        let purgeTotal = purgeArtifacts?.reduce(Int64(0)) { $0 + $1.sizeBytes } ?? 0
        return cleanTotal + duplicateTotal + purgeTotal
    }

    public var combinedItemCount: Int {
        let cleanCount = cleanPlans?.values.reduce(0) { $0 + $1.items.count } ?? 0
        let duplicateCount = duplicateGroups?.reduce(0) { $0 + max(0, $1.files.count - 1) } ?? 0
        let largeCount = largeFiles?.count ?? 0
        let purgeCount = purgeArtifacts?.count ?? 0
        return cleanCount + duplicateCount + largeCount + purgeCount
    }

    public var appFootprintBytes: Int64 {
        apps?.reduce(Int64(0)) { $0 + $1.sizeBytes } ?? 0
    }

    public var systemHealthIssueCount: Int {
        systemHealthReport?.issueCount ?? 0
    }

    public func scanEverything() async {
        isScanning = true
        let result = await Task.detached(priority: .userInitiated) {
            let clean = CleanScanner.scanAll()
            let installedApps = AppInventory.scan()
            let files = DuplicateFinder.walk()
            let duplicates = DuplicateFinder.findDuplicates(allFiles: files)
            let large = DuplicateFinder.findLargeFiles(allFiles: files)
            let privacyApps = installedApps.compactMap { app -> NetworkPrivacyAuditor.InstalledApplication? in
                guard let bundleIdentifier = app.bundleID,
                      let executablePath = Bundle(path: app.url.path)?.executableURL?.path
                else {
                    return nil
                }
                return .init(bundleIdentifier: bundleIdentifier, executablePath: executablePath)
            }
            let health: NetworkPrivacyAuditor.Report?
            let healthError: String?
            do {
                health = try NetworkPrivacyAuditor.inspect(installedApplications: privacyApps)
                healthError = nil
            } catch {
                health = nil
                healthError = error.localizedDescription
            }
            return (clean, installedApps, duplicates, large, health, healthError)
        }.value
        cleanPlans = result.0
        apps = result.1
        duplicateGroups = result.2
        largeFiles = result.3
        systemHealthReport = result.4
        systemHealthScanError = result.5
        lastScanAt = Date()
        isScanning = false
    }

    public func clearCleanPlan(for section: CleanScanner.Section) {
        cleanPlans?[section] = SafeFileDeleter.Plan(items: [], protectedItems: [], missingItems: [])
    }
}
