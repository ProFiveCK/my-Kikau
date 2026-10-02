import Foundation
import Core

/// Backs the Status dashboard's "Scan Everything" action, and is the one
/// place scan results live — each screen reads and updates them here, so
/// navigating away and back never loses a scan.
///
/// Deliberately does *not* fold in Analyze (browse-only, produces no deletion
/// plan / reclaimable total).
///
/// Purge scanning is included only when developer tools are switched on in
/// Settings — it's too developer-specific to run for everyone.
@MainActor
public final class ScanEverythingCoordinator: ObservableObject {
    public static let shared = ScanEverythingCoordinator()

    /// The steps of a full scan, in order.
    public enum Phase: Int, CaseIterable, Sendable {
        case clean, apps, files, duplicates, systemHealth, developer

        public var label: String {
            switch self {
            case .clean: "Measuring caches, logs and Trash"
            case .apps: "Listing installed apps"
            case .files: "Reading your folders"
            case .duplicates: "Comparing files"
            case .systemHealth: "Checking system settings"
            case .developer: "Looking for build artifacts"
            }
        }
    }

    @Published public private(set) var isScanning = false
    /// What the running scan is doing, and how far along it is (0…1).
    @Published public private(set) var phase: Phase?
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var progressDetail: String?

    @Published public private(set) var cleanPlans: [CleanScanner.Section: SafeFileDeleter.Plan]?
    @Published public private(set) var apps: [AppInventory.AppInfo]?
    @Published public private(set) var duplicateGroups: [DuplicateFinder.DuplicateGroup]?
    @Published public private(set) var largeFiles: [DuplicateFinder.FileEntry]?
    /// Files left out of the Files scan because they're stored in iCloud and
    /// not downloaded.
    @Published public private(set) var skippedCloudOnlyFiles = 0
    @Published public private(set) var purgeArtifacts: [ProjectArtifactScanner.Artifact]?
    @Published public private(set) var systemHealthReport: NetworkPrivacyAuditor.Report?
    @Published public private(set) var systemHealthScanError: String?
    @Published public private(set) var lastScanAt: Date?

    private var scanTask: Task<ScanResult?, Never>?

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
        let purgeCount = purgeArtifacts?.count ?? 0
        return cleanCount + duplicateCount + purgeCount
    }

    public var appFootprintBytes: Int64 {
        apps?.reduce(Int64(0)) { $0 + $1.sizeBytes } ?? 0
    }

    public var systemHealthIssueCount: Int {
        systemHealthReport?.issueCount ?? 0
    }

    private struct ScanResult: Sendable {
        var clean: [CleanScanner.Section: SafeFileDeleter.Plan]?
        var apps: [AppInventory.AppInfo]?
        var duplicates: [DuplicateFinder.DuplicateGroup]?
        var large: [DuplicateFinder.FileEntry]?
        var skippedCloudOnly = 0
        var purge: [ProjectArtifactScanner.Artifact]?
        var health: NetworkPrivacyAuditor.Report?
        var healthError: String?
    }

    /// Runs every scan. Features an administrator has disabled are skipped.
    /// Returns once the scan finishes or is cancelled; a cancelled scan
    /// leaves the previous results in place.
    public func scanEverything() async {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        phase = nil
        progressDetail = nil

        let policy = ManagedPolicy.shared
        let includeClean = !policy.isFeatureDisabled("clean")
        let includeApps = !policy.isFeatureDisabled("uninstall")
        let includeFiles = !policy.isFeatureDisabled("duplicates")
        let includeHealth = !policy.isFeatureDisabled("optimize")
        let includeDeveloper = UserDefaults.standard.bool(forKey: AppStorageKey.developerToolsEnabled)
            && !policy.isFeatureDisabled("purge")

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> ScanResult? in
            var result = ScanResult()

            if includeClean {
                await self?.enter(.clean)
                result.clean = await CleanScanner.scanAllConcurrently()
                if Task.isCancelled { return nil }
            }

            var installedApps: [AppInventory.AppInfo] = []
            if includeApps || includeHealth {
                await self?.enter(.apps)
                installedApps = AppInventory.scan()
                if includeApps { result.apps = installedApps }
                if Task.isCancelled { return nil }
            }

            if includeFiles {
                await self?.enter(.files)
                let report = DuplicateFinder.walkReport { count in
                    Task { await self?.detail("\(count.formatted()) files") }
                }
                if Task.isCancelled { return nil }
                result.skippedCloudOnly = report.skippedCloudOnly

                await self?.enter(.duplicates)
                result.duplicates = DuplicateFinder.findDuplicates(allFiles: report.files) { hashed, total in
                    guard hashed % 8 == 0 || hashed == total else { return }
                    Task { await self?.detail("\(hashed.formatted()) of \(total.formatted()) candidates") }
                }
                if Task.isCancelled { return nil }
                result.large = DuplicateFinder.findLargeFiles(allFiles: report.files)
            }

            if includeHealth {
                await self?.enter(.systemHealth)
                let privacyApps = installedApps.compactMap { app -> NetworkPrivacyAuditor.InstalledApplication? in
                    guard let bundleIdentifier = app.bundleID,
                          let executablePath = Bundle(path: app.url.path)?.executableURL?.path
                    else {
                        return nil
                    }
                    return .init(bundleIdentifier: bundleIdentifier, executablePath: executablePath)
                }
                do {
                    result.health = try NetworkPrivacyAuditor.inspect(installedApplications: privacyApps)
                } catch {
                    result.healthError = error.localizedDescription
                }
                if Task.isCancelled { return nil }
            }

            if includeDeveloper {
                await self?.enter(.developer)
                result.purge = ProjectArtifactScanner.scan()
                if Task.isCancelled { return nil }
            }
            return result
        }
        scanTask = task
        let result = await task.value
        scanTask = nil

        if let result {
            if includeClean { cleanPlans = result.clean }
            if includeApps { apps = result.apps }
            if includeFiles {
                duplicateGroups = result.duplicates
                largeFiles = result.large
                skippedCloudOnlyFiles = result.skippedCloudOnly
            }
            if includeHealth {
                systemHealthReport = result.health
                systemHealthScanError = result.healthError
            }
            purgeArtifacts = includeDeveloper ? result.purge : nil
            lastScanAt = Date()
            Log.scan.info("full scan finished: \(self.combinedItemCount) items, \(self.combinedReclaimableBytes) bytes reclaimable")
        } else {
            Log.scan.info("full scan cancelled")
        }
        isScanning = false
        phase = nil
        progressDetail = nil
        progress = result == nil ? 0 : 1
    }

    /// Stops a running full scan. Results from the previous scan stay.
    public func cancelScan() {
        scanTask?.cancel()
    }

    private func enter(_ newPhase: Phase) {
        phase = newPhase
        progressDetail = nil
        progress = Double(newPhase.rawValue) / Double(Phase.allCases.count)
    }

    private func detail(_ text: String) {
        guard isScanning else { return }
        progressDetail = text
    }

    // MARK: - Updates from individual screens

    /// A screen ran its own scan: adopt the result so the dashboard and the
    /// screen agree, and so it survives navigating away.
    public func setCleanPlans(_ plans: [CleanScanner.Section: SafeFileDeleter.Plan]) {
        cleanPlans = plans
    }

    public func setApps(_ scanned: [AppInventory.AppInfo]) {
        apps = scanned
    }

    public func setFiles(
        duplicates: [DuplicateFinder.DuplicateGroup],
        large: [DuplicateFinder.FileEntry],
        skippedCloudOnly: Int
    ) {
        duplicateGroups = duplicates
        largeFiles = large
        skippedCloudOnlyFiles = skippedCloudOnly
    }

    public func setPurgeArtifacts(_ artifacts: [ProjectArtifactScanner.Artifact]) {
        purgeArtifacts = artifacts
    }

    public func clearCleanPlan(for section: CleanScanner.Section) {
        cleanPlans?[section] = .empty
    }

    /// Drops removed items from every Clean section's plan.
    public func removeCleanItems(ids: Set<String>) {
        guard !ids.isEmpty, let plans = cleanPlans else { return }
        cleanPlans = plans.mapValues { $0.removing(ids) }
    }

    /// Called after `UninstallView` successfully removes an app, so the
    /// dashboard's cached Apps count/footprint doesn't keep counting one
    /// that's already gone.
    public func removeApp(id: String) {
        apps?.removeAll { $0.id == id }
    }

    /// Called after duplicate copies are removed. A group disappears once
    /// fewer than two copies remain.
    public func removeDuplicateFiles(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        duplicateGroups = duplicateGroups?.compactMap { $0.removing(ids) }
        largeFiles?.removeAll { ids.contains($0.id) }
    }

    /// Records the user's choice of which copy to keep in a group.
    public func setKeeper(groupID: String, fileID: String) {
        guard let index = duplicateGroups?.firstIndex(where: { $0.id == groupID }) else { return }
        duplicateGroups?[index] = duplicateGroups![index].keeping(fileID)
    }

    public func removeDuplicateGroups(ids: Set<String>) {
        duplicateGroups?.removeAll { ids.contains($0.id) }
    }

    /// Called after selected large files are removed.
    public func removeLargeFiles(ids: Set<String>) {
        largeFiles?.removeAll { ids.contains($0.id) }
        duplicateGroups = duplicateGroups?.compactMap { $0.removing(ids) }
    }

    public func removePurgeArtifacts(ids: Set<String>) {
        purgeArtifacts?.removeAll { ids.contains($0.id) }
    }
}
