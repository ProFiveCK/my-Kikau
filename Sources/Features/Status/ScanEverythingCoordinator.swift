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

    public enum ScanMode: String, CaseIterable, Identifiable, Sendable {
        case quick, full
        public var id: String {
            rawValue
        }

        public var title: String {
            self == .quick ? "Quick scan" : "Full scan"
        }

        public var summary: String {
            self == .quick
                ? "Everyday cleanup and startup items. Apps, files and system care keep their previous results."
                : "Cleanup, applications, duplicates, large files, system care and startup. Similar photos run separately in My files."
        }

        public var phases: [Phase] {
            self == .quick ? [.clean, .startup] : Phase.allCases
        }
    }

    @Published public private(set) var lastScanMode: ScanMode?
    @Published public private(set) var activeScanMode: ScanMode?
    private var activePhases: [Phase] = []

    /// The steps of a full scan, in order.
    public enum Phase: Int, CaseIterable, Sendable {
        case clean, apps, files, duplicates, systemHealth, maintenance, startup, developer

        public var label: String {
            switch self {
            case .clean: String(localized: "Measuring caches, logs and Trash")
            case .apps: String(localized: "Listing installed apps")
            case .files: String(localized: "Reading your folders")
            case .duplicates: String(localized: "Comparing files")
            case .systemHealth: String(localized: "Checking system settings")
            case .maintenance: String(localized: "Checking maintenance recommendations")
            case .startup: String(localized: "Reading startup items")
            case .developer: String(localized: "Looking for build artifacts")
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

    @Published public private(set) var maintenanceResults: [String: MaintenanceRunner.Result]?
    @Published public var maintenanceApplyResults: [String: MaintenanceRunner.Result] = [:]
    @Published public var selectedMaintenanceTasks: Set<String> = []
    @Published public private(set) var startupItems: [StartupItems.Item]?
    @Published public var selectedStartupIDs: Set<String> = []
    public enum Area: String, CaseIterable, Sendable { case clean, apps, files, startup, storage, maintenance, developer }
    @Published public private(set) var coverage: [Area: ScanCoverage] = [:]
    @Published public private(set) var scannedAt: [Area: Date] = [:]
    public var maintenanceIssueCount: Int {
        maintenanceResults?.values.filter(\.outcome.needsAction).count ?? 0
    }

    private var scanTask: Task<ScanResult?, Never>?
    private var readCancellation: DiskScanner.Token?

    init() {}

    public var hasResults: Bool {
        cleanPlans != nil || apps != nil || duplicateGroups != nil || largeFiles != nil
            || purgeArtifacts != nil || systemHealthReport != nil || systemHealthScanError != nil
            || maintenanceResults != nil || startupItems != nil
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
        var maintenance: [String: MaintenanceRunner.Result]?
        var startup: [StartupItems.Item]?
        var coverage: [Area: ScanCoverage] = [:]
    }

    /// Runs every scan. Features an administrator has disabled are skipped.
    /// Returns once the scan finishes or is cancelled; a cancelled scan
    /// leaves the previous results in place.
    public func scanEverything(mode: ScanMode = .full) async {
        guard !isScanning,
              let lease = WorkCoordinator.shared.begin(mode.title, cancel: { [weak self] in self?.cancelScan() }) else { return }
        defer { WorkCoordinator.shared.finish(lease) }
        isScanning = true
        activeScanMode = mode
        progress = 0
        phase = nil
        progressDetail = nil

        let policy = ManagedPolicy.shared
        let includeClean = !policy.isFeatureDisabled("clean")
        let includeApps = mode.phases.contains(.apps) && !policy.isFeatureDisabled("uninstall")
        let includeFiles = mode.phases.contains(.files) && !policy.isFeatureDisabled("duplicates")
        let includeHealth = mode.phases.contains(.maintenance) && !policy.isFeatureDisabled("optimize")
        let includeStartup = !policy.isFeatureDisabled("startup")
        let includeDeveloper = mode.phases.contains(.developer) && UserDefaults.standard.bool(forKey: AppStorageKey.developerToolsEnabled)
            && !policy.isFeatureDisabled("purge")

        activePhases = mode.phases.filter { phase in
            switch phase {
            case .clean: includeClean
            case .apps: includeApps || includeHealth
            case .files, .duplicates: includeFiles
            case .systemHealth, .maintenance: includeHealth
            case .startup: includeStartup
            case .developer: includeDeveloper
            }
        }
        let cancellation = DiskScanner.Token()
        readCancellation = cancellation
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> ScanResult? in
            var result = ScanResult()

            if includeClean {
                await self?.enter(.clean)
                let coverage = ScanCoverageRecorder()
                result.clean = await CleanScanner.scanAllConcurrently(coverage: coverage)
                result.coverage[.clean] = coverage.snapshot
                if Task.isCancelled {
                    return nil
                }
            }

            var installedApps: [AppInventory.AppInfo] = []
            if includeApps || includeHealth {
                await self?.enter(.apps)
                let coverage = ScanCoverageRecorder()
                installedApps = AppInventory.scan(coverage: coverage, shouldContinue: { !cancellation.isCancelled })
                if includeApps {
                    result.coverage[.apps] = coverage.snapshot
                }
                if includeApps {
                    result.apps = installedApps
                }
                if Task.isCancelled {
                    return nil
                }
            }

            if includeFiles {
                await self?.enter(.files)
                let coverage = ScanCoverageRecorder()
                let report = DuplicateFinder.walkReport(coverage: coverage) { count in
                    Task { await self?.detail("\(count.formatted()) files", owner: lease) }
                }
                if Task.isCancelled {
                    return nil
                }
                result.skippedCloudOnly = report.skippedCloudOnly
                result.coverage[.files] = report.coverage

                await self?.enter(.duplicates)
                result.duplicates = DuplicateFinder.findDuplicates(allFiles: report.files, coverage: coverage) { hashed, total in
                    guard hashed % 8 == 0 || hashed == total else { return }
                    Task { await self?.detail("\(hashed.formatted()) of \(total.formatted()) candidates", owner: lease) }
                }
                if Task.isCancelled {
                    return nil
                }
                result.large = DuplicateFinder.findLargeFiles(allFiles: report.files)
                result.coverage[.files] = coverage.snapshot
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
                if Task.isCancelled {
                    return nil
                }
            }

            if includeHealth {
                await self?.enter(.maintenance)
                let runner = MaintenanceRunner()
                var checks: [String: MaintenanceRunner.Result] = [:]
                for task in MaintenanceCatalog.tasks where task.kind == .maintenance {
                    if Task.isCancelled {
                        return nil
                    }
                    await self?.detail(task.name)
                    checks[task.id] = await runner.run(taskID: task.id, dryRun: true)
                }
                result.maintenance = checks
            }
            if includeStartup {
                await self?.enter(.startup)
                let coverage = ScanCoverageRecorder()
                result.startup = StartupItems.scan(coverage: coverage)
                result.coverage[.startup] = coverage.snapshot
                if Task.isCancelled {
                    return nil
                }
            }
            if includeDeveloper {
                await self?.enter(.developer)
                result.purge = ProjectArtifactScanner.scan()
                if Task.isCancelled {
                    return nil
                }
            }
            return result
        }
        scanTask = task
        var result = await withTaskCancellationHandler { await task.value } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
        if task.isCancelled {
            result = nil
        }
        scanTask = nil
        readCancellation = nil

        if let result {
            if includeClean {
                cleanPlans = result.clean
            }
            if includeApps {
                apps = result.apps
            }
            if includeFiles {
                duplicateGroups = result.duplicates
                largeFiles = result.large
                skippedCloudOnlyFiles = result.skippedCloudOnly
            }
            if includeHealth {
                systemHealthReport = result.health.map { NetworkPrivacyFindingStore.shared.applyingIgnores(to: $0) }
                systemHealthScanError = result.healthError
            }
            if includeHealth {
                var checks = result.maintenance ?? [:]
                if let report = systemHealthReport {
                    checks["network_privacy"] = .init(outcome: MaintenanceRunner().networkPrivacyOutcome(for: report))
                } else if let error = result.healthError {
                    checks["network_privacy"] = .init(outcome: .unavailable(error))
                }
                setMaintenanceResults(checks)
                scannedAt[.maintenance] = Date()
            }
            if includeStartup, let items = result.startup {
                setStartupItems(items)
            }
            for (area, report) in result.coverage {
                coverage[area] = report; scannedAt[area] = Date()
            }
            if includeDeveloper {
                purgeArtifacts = result.purge
                scannedAt[.developer] = Date()
            }
            lastScanMode = mode
            lastScanAt = Date()
            let (items, bytes) = (combinedItemCount, combinedReclaimableBytes)
            Log.scan.info("\(mode.rawValue, privacy: .public) scan finished: \(items) items, \(bytes) bytes reclaimable")
        } else {
            Log.scan.info("\(mode.rawValue, privacy: .public) scan cancelled")
        }
        isScanning = false
        activeScanMode = nil
        phase = nil
        progressDetail = nil
        progress = result == nil ? 0 : 1
    }

    /// Stops a running full scan. Results from the previous scan stay.
    public func cancelScan() {
        readCancellation?.cancel()
        scanTask?.cancel()
    }

    private func enter(_ newPhase: Phase) {
        phase = newPhase
        progressDetail = nil
        progress = Double(activePhases.firstIndex(of: newPhase) ?? 0) / Double(max(1, activePhases.count))
    }

    private func detail(_ text: String, owner: UUID? = nil) {
        if let owner, WorkCoordinator.shared.activity?.id != owner {
            return
        }
        guard isScanning else { return }
        progressDetail = text
    }

    // MARK: - Updates from individual screens

    /// A screen ran its own scan: adopt the result so the dashboard and the
    /// screen agree, and so it survives navigating away.
    public func setCleanPlans(_ plans: [CleanScanner.Section: SafeFileDeleter.Plan], coverage report: ScanCoverage? = nil) {
        cleanPlans = plans
        if let report {
            coverage[.clean] = report
        }; scannedAt[.clean] = Date()
    }

    public func setApps(_ scanned: [AppInventory.AppInfo], coverage report: ScanCoverage? = nil) {
        apps = scanned
        if let report {
            coverage[.apps] = report
        }; scannedAt[.apps] = Date()
    }

    public func setSystemHealthReport(_ report: NetworkPrivacyAuditor.Report) {
        systemHealthReport = NetworkPrivacyFindingStore.shared.applyingIgnores(to: report)
        systemHealthScanError = nil
        if let filtered = systemHealthReport {
            maintenanceResults?["network_privacy"] = .init(outcome: MaintenanceRunner().networkPrivacyOutcome(for: filtered))
        }
    }

    public func setSystemHealthScanError(_ message: String) {
        systemHealthReport = nil
        systemHealthScanError = message
        maintenanceResults?["network_privacy"] = .init(outcome: .unavailable(message))
    }

    public func setFiles(
        duplicates: [DuplicateFinder.DuplicateGroup],
        large: [DuplicateFinder.FileEntry],
        skippedCloudOnly: Int,
        coverage report: ScanCoverage? = nil
    ) {
        duplicateGroups = duplicates
        largeFiles = large
        skippedCloudOnlyFiles = skippedCloudOnly
        if let report {
            coverage[.files] = report
        }; scannedAt[.files] = Date()
    }

    public func setMaintenanceResults(_ results: [String: MaintenanceRunner.Result]) {
        let previous = maintenanceResults
        maintenanceResults = results
        scannedAt[.maintenance] = Date()
        maintenanceApplyResults = [:]
        let eligible = Set(results.filter { $0.value.outcome.needsAction && $0.key != "network_privacy" }.map(\.key))
        selectedMaintenanceTasks = previous == nil ? eligible : selectedMaintenanceTasks.intersection(eligible)
    }

    public func setStartupItems(_ items: [StartupItems.Item], coverage report: ScanCoverage? = nil) {
        startupItems = items
        selectedStartupIDs.formIntersection(Set(items.map(\.id)))
        if let report {
            coverage[.startup] = report
        }; scannedAt[.startup] = Date()
    }

    public func setCoverage(_ report: ScanCoverage, for area: Area) {
        coverage[area] = report; scannedAt[area] = Date()
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
