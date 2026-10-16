import AppKit
import Foundation
import Core
import Features

// Per-screen scan state. These are long-lived singletons rather than view
// `@State`, because the detail pane is rebuilt on every sidebar change: a
// scan started on one screen keeps running — and stays cancellable — while
// the user looks at another, and its results land in
// `ScanEverythingCoordinator`, where both the screen and the dashboard read
// them.

@MainActor
final class CleanModel: ObservableObject {
    static let shared = CleanModel()

    @Published private(set) var isScanning = false
    /// Sections measured so far, for the progress bar.
    @Published private(set) var sectionsDone = 0
    private var task: Task<Void, Never>?

    private init() {}

    var sectionCount: Int {
        CleanScanner.Section.allCases.count
    }

    func scan() {
        guard !isScanning,
              let lease = WorkCoordinator.shared.begin("Measuring cleanup", cancel: { [weak self] in self?.cancel() }) else { return }
        isScanning = true
        sectionsDone = 0
        task = Task {
            defer { WorkCoordinator.shared.finish(lease) }
            let coverage = ScanCoverageRecorder()
            let plans = await CleanScanner.scanAllConcurrently(coverage: coverage) { _ in
                Task { @MainActor in
                    guard WorkCoordinator.shared.activity?.id == lease else { return }
                    CleanModel.shared.sectionsDone += 1
                }
            }
            if !Task.isCancelled {
                ScanEverythingCoordinator.shared.setCleanPlans(plans, coverage: coverage.snapshot)
            }
            isScanning = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }
}

@MainActor
final class AppsModel: ObservableObject {
    static let shared = AppsModel()

    @Published private(set) var isScanning = false
    /// Newer versions found by the last update check, keyed by `AppInfo.id`.
    @Published private(set) var updateReport = AppUpdateChecker.Report()
    @Published var selectedAppIDs: Set<String> = []
    private var checkedVersions: [String: String] = [:]
    private func versionKey(_ app: AppInventory.AppInfo) -> String {
        (app.version ?? "") + "|" + String(app.lastModified?.timeIntervalSince1970 ?? 0)
    }

    func status(for app: AppInventory.AppInfo) -> AppUpdateChecker.CheckStatus? {
        guard checkedVersions[app.id] == versionKey(app) else { return nil }
        return updateReport.statuses[app.id]
    }

    func report(for apps: [AppInventory.AppInfo]) -> AppUpdateChecker.Report {
        .init(statuses: Dictionary(uniqueKeysWithValues: apps.compactMap { app in status(for: app).map { (app.id, $0) } }))
    }

    var updates: [String: AppUpdateChecker.Update] {
        report(for: ScanEverythingCoordinator.shared.apps ?? []).updates
    }

    func reconcileSelection() {
        selectedAppIDs.formIntersection(Set(ScanEverythingCoordinator.shared.apps?.map(\.id) ?? []))
    }

    private var inventoryTask: Task<Void, Never>?
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var updateProgress: String?
    @Published private(set) var lastUpdateCheck: Date?
    private var updateTask: Task<Void, Never>?

    private init() {}

    func scan() {
        guard !isScanning, let lease = WorkCoordinator.shared.begin(
            "Listing applications",
            cancel: { [weak self] in self?.inventoryTask?.cancel() }
        ) else { return }
        isScanning = true
        inventoryTask = Task {
            defer { isScanning = false; inventoryTask = nil; WorkCoordinator.shared.finish(lease) }
            let coverage = ScanCoverageRecorder()
            let cancellation = DiskScanner.Token()
            let work = Task.detached(priority: .userInitiated) { AppInventory.scan(
                coverage: coverage,
                shouldContinue: { !cancellation.isCancelled }
            ) }
            let apps = await withTaskCancellationHandler { await work.value } onCancel: { cancellation.cancel(); work.cancel() }
            guard !Task.isCancelled else { return }
            ScanEverythingCoordinator.shared.setApps(apps, coverage: coverage.snapshot)
            let ids = Set(apps.map(\.id))
            selectedAppIDs.formIntersection(ids)
            // Installed versions may have changed. A fresh inventory needs a fresh check.
            updateReport = .init()
            checkedVersions = [:]
            lastUpdateCheck = nil
        }
    }

    /// Asks each app's own update feed, and the App Store, whether a newer
    /// version exists. Only runs when the user asks for it.
    func checkForUpdates(_ apps: [AppInventory.AppInfo]) {
        guard !isCheckingUpdates, let lease = WorkCoordinator.shared.begin(
            "Checking app updates",
            kind: .updates,
            cancel: { [weak self] in self?.cancelUpdateCheck() }
        ) else { return }
        isCheckingUpdates = true
        updateProgress = nil
        updateTask = Task {
            defer { WorkCoordinator.shared.finish(lease) }
            let found = await AppUpdateChecker.checkReport(apps) { done, total in
                Task { @MainActor in
                    guard WorkCoordinator.shared.activity?.id == lease else { return }
                    AppsModel.shared.updateProgress = "\(done) of \(total)"
                }
            }
            if !Task.isCancelled {
                checkedVersions = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, versionKey($0)) })
                updateReport = found
                lastUpdateCheck = Date()
            }
            isCheckingUpdates = false
            updateProgress = nil
            updateTask = nil
        }
    }

    func cancelUpdateCheck() {
        updateTask?.cancel()
    }
}

@MainActor
final class FilesModel: ObservableObject {
    static let shared = FilesModel()
    @Published var selectedLargeFiles: Set<String> = []
    @Published var selectedSimilar: Set<String> = []

    @Published private(set) var isScanning = false
    @Published private(set) var progressTitle = ""
    @Published private(set) var progressDetail: String?
    @Published private(set) var progressFraction: Double?
    private var task: Task<Void, Never>?

    private init() {}

    func scan() {
        guard !isScanning,
              let lease = WorkCoordinator.shared.begin("Scanning files", cancel: { [weak self] in self?.cancel() }) else { return }
        isScanning = true
        progressTitle = "Reading your folders"
        progressDetail = nil
        progressFraction = nil

        let work = Task.detached(priority: .userInitiated) { () -> (
            [DuplicateFinder.DuplicateGroup], [DuplicateFinder.FileEntry], Int, ScanCoverage
        )? in
            let coverage = ScanCoverageRecorder()
            let report = DuplicateFinder.walkReport(coverage: coverage) { count in
                Task { @MainActor in
                    guard WorkCoordinator.shared.activity?.id == lease else { return }
                    FilesModel.shared.progressDetail = "\(count.formatted()) files"
                }
            }
            if Task.isCancelled {
                return nil
            }
            await MainActor.run {
                FilesModel.shared.progressTitle = "Comparing files"
                FilesModel.shared.progressDetail = nil
            }
            let duplicates = DuplicateFinder.findDuplicates(allFiles: report.files, coverage: coverage) { hashed, total in
                guard hashed % 8 == 0 || hashed == total else { return }
                Task { @MainActor in
                    guard WorkCoordinator.shared.activity?.id == lease else { return }
                    FilesModel.shared.progressFraction = total > 0 ? Double(hashed) / Double(total) : nil
                    FilesModel.shared.progressDetail = "\(hashed.formatted()) of \(total.formatted()) candidates"
                }
            }
            if Task.isCancelled {
                return nil
            }
            return (duplicates, DuplicateFinder.findLargeFiles(allFiles: report.files), report.skippedCloudOnly, coverage.snapshot)
        }
        task = Task {
            defer { WorkCoordinator.shared.finish(lease) }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            if let (duplicates, large, skipped, coverage) = result {
                ScanEverythingCoordinator.shared.setFiles(
                    duplicates: duplicates,
                    large: large,
                    skippedCloudOnly: skipped,
                    coverage: coverage
                )
            }
            isScanning = false
            progressDetail = nil
            progressFraction = nil
            task = nil
        }
    }

    /// Pictures that look alike. Separate from the main Files scan because
    /// it reads every image and takes longer.
    @Published private(set) var similar: SimilarImageFinder.Report?
    @Published private(set) var similarCoverage: ScanCoverage?

    func findSimilar() {
        guard !isScanning,
              let lease = WorkCoordinator.shared.begin("Scanning files", cancel: { [weak self] in self?.cancel() }) else { return }
        isScanning = true
        progressTitle = "Reading your folders"
        progressDetail = nil
        progressFraction = nil

        let work = Task.detached(priority: .userInitiated) { () -> (SimilarImageFinder.Report, ScanCoverage)? in
            let walk = DuplicateFinder.walkReport { count in
                Task { @MainActor in
                    guard WorkCoordinator.shared.activity?.id == lease else { return }
                    FilesModel.shared.progressDetail = "\(count.formatted()) files"
                }
            }
            let files = walk.files
            if Task.isCancelled {
                return nil
            }
            await MainActor.run {
                FilesModel.shared.progressTitle = "Looking at your pictures"
                FilesModel.shared.progressDetail = nil
            }
            let report = SimilarImageFinder.find(in: files) { done, total in
                Task { @MainActor in
                    guard WorkCoordinator.shared.activity?.id == lease else { return }
                    FilesModel.shared.progressFraction = total > 0 ? Double(done) / Double(total) : nil
                    FilesModel.shared.progressDetail = "\(done.formatted()) of \(total.formatted()) pictures"
                }
            }
            return Task.isCancelled ? nil : (report, walk.coverage)
        }
        task = Task {
            defer { WorkCoordinator.shared.finish(lease) }
            let report = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            if let (report, coverage) = report {
                similar = report
                similarCoverage = coverage
            }
            isScanning = false
            progressDetail = nil
            progressFraction = nil
            task = nil
        }
    }

    /// Drops removed pictures; a group with one picture left is no longer a group.
    func removeSimilarFiles(ids: Set<String>) {
        guard !ids.isEmpty, var report = similar else { return }
        report.groups = report.groups.compactMap { group in
            let remaining = group.files.filter { !ids.contains($0.id) }
            return remaining.count > 1 ? SimilarImageFinder.Group(id: group.id, files: remaining) : nil
        }
        similar = report
    }

    func cancel() {
        task?.cancel()
    }
}

@MainActor
final class PurgeModel: ObservableObject {
    static let shared = PurgeModel()

    @Published private(set) var isScanning = false

    private init() {}

    private var task: Task<Void, Never>?
    func scan() {
        guard !isScanning, let lease = WorkCoordinator.shared.begin(
            "Scanning developer files",
            cancel: { [weak self] in self?.task?.cancel() }
        ) else { return }
        isScanning = true
        task = Task {
            defer { isScanning = false; task = nil; WorkCoordinator.shared.finish(lease) }
            let work = Task.detached(priority: .userInitiated) { ProjectArtifactScanner.scan() }
            let artifacts = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            ScanEverythingCoordinator.shared.setPurgeArtifacts(artifacts)
        }
    }
}

/// A deletion plan waiting in the review sheet.
struct ReviewRequest: Identifiable {
    let id = UUID()
    let plan: SafeFileDeleter.Plan
    let title: String
    var subtitle: String?
    let action: String
    /// Whether every item starts ticked in the review sheet.
    var preselected = true
}

/// Icons for app bundles, cached — `NSWorkspace.icon(forFile:)` is too slow
/// to call from a row's `body` on every redraw.
@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

/// Small previews for picture rows, decoded off the main thread and cached.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    static func load(_ url: URL, pixelSize: Int = 144) async -> NSImage? {
        if let hit = cached(url) {
            return hit
        }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let cgImage = SimilarImageFinder.thumbnail(of: url, maxPixelSize: pixelSize) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        if let image {
            cache.setObject(image, forKey: url.path as NSString)
        }
        return image
    }
}
