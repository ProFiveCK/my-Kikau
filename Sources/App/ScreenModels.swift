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
        guard !isScanning else { return }
        isScanning = true
        sectionsDone = 0
        task = Task {
            let plans = await CleanScanner.scanAllConcurrently { _ in
                Task { @MainActor in CleanModel.shared.sectionsDone += 1 }
            }
            if !Task.isCancelled {
                ScanEverythingCoordinator.shared.setCleanPlans(plans)
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

    private init() {}

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let apps = await Task.detached(priority: .userInitiated) { AppInventory.scan() }.value
            ScanEverythingCoordinator.shared.setApps(apps)
            isScanning = false
        }
    }
}

@MainActor
final class FilesModel: ObservableObject {
    static let shared = FilesModel()

    @Published private(set) var isScanning = false
    @Published private(set) var progressTitle = ""
    @Published private(set) var progressDetail: String?
    @Published private(set) var progressFraction: Double?
    private var task: Task<Void, Never>?

    private init() {}

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        progressTitle = "Reading your folders"
        progressDetail = nil
        progressFraction = nil

        let work = Task.detached(priority: .userInitiated) { () -> (
            [DuplicateFinder.DuplicateGroup], [DuplicateFinder.FileEntry], Int
        )? in
            let report = DuplicateFinder.walkReport { count in
                Task { @MainActor in FilesModel.shared.progressDetail = "\(count.formatted()) files" }
            }
            if Task.isCancelled {
                return nil
            }
            await MainActor.run {
                FilesModel.shared.progressTitle = "Comparing files"
                FilesModel.shared.progressDetail = nil
            }
            let duplicates = DuplicateFinder.findDuplicates(allFiles: report.files) { hashed, total in
                guard hashed % 8 == 0 || hashed == total else { return }
                Task { @MainActor in
                    FilesModel.shared.progressFraction = total > 0 ? Double(hashed) / Double(total) : nil
                    FilesModel.shared.progressDetail = "\(hashed.formatted()) of \(total.formatted()) candidates"
                }
            }
            if Task.isCancelled {
                return nil
            }
            return (duplicates, DuplicateFinder.findLargeFiles(allFiles: report.files), report.skippedCloudOnly)
        }
        task = Task {
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            if let (duplicates, large, skipped) = result {
                ScanEverythingCoordinator.shared.setFiles(duplicates: duplicates, large: large, skippedCloudOnly: skipped)
            }
            isScanning = false
            progressDetail = nil
            progressFraction = nil
            task = nil
        }
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

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let artifacts = await Task.detached(priority: .userInitiated) { ProjectArtifactScanner.scan() }.value
            ScanEverythingCoordinator.shared.setPurgeArtifacts(artifacts)
            isScanning = false
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
