import Combine
import Foundation
import Core

/// Keeps the last Analyze scan alive while the app is running, even when the
/// user navigates away from the Analyse screen.
@MainActor
public final class AnalyzeScanSession: ObservableObject {
    public static let shared = AnalyzeScanSession()

    @Published public private(set) var entries: [DiskScanner.Entry] = []
    /// `nil` while showing the whole-disk overview (the root of the hierarchy);
    /// a real directory URL once the user has drilled in.
    @Published public private(set) var currentDir: URL?
    @Published public private(set) var isScanning = false
    /// Folder the running scan is measuring right now, for the progress line.
    @Published public private(set) var progressPath: String?
    @Published public private(set) var lastScanAt: Date?
    @Published public private(set) var isOverview = false
    /// Startup volume name, filled in once an overview scan has run — used for
    /// the root breadcrumb label.
    @Published public private(set) var volumeName = "Macintosh HD"
    /// Whether dot-prefixed entries show as their own rows (see
    /// `DiskScanner.scan(_:includeHidden:)`). Persisted so the choice sticks.
    @Published public var showHidden: Bool {
        didSet {
            guard oldValue != showHidden else { return }
            UserDefaults.standard.set(showHidden, forKey: Self.showHiddenKey)
            reapplyHiddenFilter()
        }
    }

    private static let showHiddenKey = "analyze.showHidden"
    private static let overviewCacheKey = "__overview__"

    private var cachedEntries: [String: [DiskScanner.Entry]] = [:]
    private var cachedScanDates: [String: Date] = [:]
    /// Bumped on every scan request; a detached walk only writes its results
    /// (and clears `isScanning`) if it's still the latest one. Guards against a
    /// slow walk finishing after the user has already navigated somewhere else
    /// and leaving `isScanning` stuck on.
    private var scanToken = 0
    /// The walk currently in flight. Cancelled when a newer scan starts or
    /// the user presses Cancel, so a superseded walk stops reading the disk.
    private var activeWalk: DiskScanner.Token?

    private init() {
        let defaults = UserDefaults.standard
        showHidden = defaults.object(forKey: Self.showHiddenKey) as? Bool ?? true
    }

    public var hasResults: Bool {
        !entries.isEmpty
    }

    /// Cache key for a directory scan at the current `showHidden` setting.
    /// Overview results don't depend on the flag, so they use a fixed key.
    private func cacheKey(for directory: URL) -> String {
        "\(directory.path)|hidden=\(showHidden)"
    }

    public func scan(_ directory: URL, useCache: Bool = true) {
        currentDir = directory
        isOverview = false
        scanToken += 1
        let token = scanToken
        let key = cacheKey(for: directory)
        if useCache, let cached = cachedEntries[key] {
            activeWalk?.cancel()
            entries = cached
            lastScanAt = cachedScanDates[key]
            finishWalk()
            return
        }
        isScanning = true
        if !useCache {
            // Re-measure this folder and everything beneath it.
            DiskScanner.SizeCache.shared.invalidate(directory.path)
            let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            // Listings beneath this folder, and listings of the folders that
            // contain it (their totals included it), are all out of date.
            cachedEntries = cachedEntries.filter { key, _ in
                if key.hasPrefix(prefix) {
                    return false
                }
                if key == Self.overviewCacheKey {
                    return false
                }
                let listed = key.components(separatedBy: "|hidden=").first ?? key
                return !(directory.path == listed || directory.path.hasPrefix(listed.hasSuffix("/") ? listed : listed + "/"))
            }
        }
        let includeHidden = showHidden
        let walk = beginWalk(token: token)
        Task.detached(priority: .userInitiated) {
            let result = DiskScanner.scan(directory, includeHidden: includeHidden, token: walk)
            let scannedAt = Date()
            await MainActor.run {
                guard !walk.isCancelled else { return }
                self.cachedEntries[key] = result
                self.cachedScanDates[key] = scannedAt
                // A newer scan may have started while this walk ran — if so,
                // keep the cache write above but don't disturb the UI.
                guard token == self.scanToken else { return }
                self.entries = result
                self.lastScanAt = scannedAt
                self.finishWalk()
            }
        }
    }

    /// Cancels whatever walk is running and starts a fresh token whose
    /// progress reports land on `progressPath`.
    private func beginWalk(token: Int) -> DiskScanner.Token {
        activeWalk?.cancel()
        let walk = DiskScanner.Token { [weak self] path in
            Task { @MainActor in
                guard let self, self.scanToken == token, self.isScanning else { return }
                self.progressPath = path
            }
        }
        activeWalk = walk
        progressPath = nil
        return walk
    }

    private func finishWalk() {
        isScanning = false
        progressPath = nil
        activeWalk = nil
    }

    /// Something was removed elsewhere in the app, so every remembered size
    /// may be wrong. The listing on screen stays (with its original scan
    /// time); the next navigation or rescan measures again.
    public func markStale() {
        DiskScanner.SizeCache.shared.removeAll()
        cachedEntries.removeAll()
        cachedScanDates.removeAll()
    }

    /// Stops the scan in progress. Whatever was on screen before stays.
    public func cancelScan() {
        guard isScanning else { return }
        activeWalk?.cancel()
        scanToken += 1
        finishWalk()
    }

    /// Scans the whole-disk overview — the root of the hierarchy: measured
    /// top-level folders plus computed "macOS System" and "Free" rows.
    public func scanVolumeOverview(useCache: Bool = true) {
        currentDir = nil
        isOverview = true
        scanToken += 1
        let token = scanToken
        if useCache, let cached = cachedEntries[Self.overviewCacheKey] {
            activeWalk?.cancel()
            entries = cached
            lastScanAt = cachedScanDates[Self.overviewCacheKey]
            finishWalk()
            if let info = DiskScanner.startupVolumeInfo() {
                volumeName = info.name
            }
            return
        }
        isScanning = true
        if !useCache {
            // A fresh overview re-measures everything, so every remembered
            // folder total and every cached listing is stale.
            DiskScanner.SizeCache.shared.removeAll()
            cachedEntries.removeAll()
            cachedScanDates.removeAll()
        }
        let walk = beginWalk(token: token)
        Task.detached(priority: .userInitiated) {
            let info = DiskScanner.startupVolumeInfo()
            let result = DiskScanner.volumeOverview(token: walk)
            let scannedAt = Date()
            await MainActor.run {
                guard !walk.isCancelled else { return }
                self.cachedEntries[Self.overviewCacheKey] = result
                self.cachedScanDates[Self.overviewCacheKey] = scannedAt
                guard token == self.scanToken else { return }
                if let info {
                    self.volumeName = info.name
                }
                self.entries = result
                self.lastScanAt = scannedAt
                self.finishWalk()
            }
        }
    }

    public func rescanCurrent() {
        if isOverview || currentDir == nil {
            scanVolumeOverview(useCache: false)
        } else if let dir = currentDir {
            scan(dir, useCache: false)
        }
    }

    /// The parent of the current level, or `nil` if already at the root.
    /// Navigating up out of a top-level folder returns to the overview.
    public func navigateUp() {
        guard let dir = currentDir else { return }
        let parent = dir.deletingLastPathComponent()
        if dir.path == "/" || parent.path == "/" || parent.path == dir.path {
            scanVolumeOverview()
        } else {
            scan(parent)
        }
    }

    public var canNavigateUp: Bool {
        !isOverview && currentDir != nil
    }

    /// Re-runs the current directory scan when `showHidden` changes. The
    /// overview is unaffected (it always accounts for everything).
    private func reapplyHiddenFilter() {
        guard !isOverview, let dir = currentDir else { return }
        scan(dir)
    }

    /// Adopts an already-cached overview scan into the published state if one
    /// exists (e.g. from the launch-time `preload`). Deliberately does NOT fall
    /// back to triggering a fresh scan when there's no cache: a tab you merely
    /// opened should never silently kick off an expensive disk walk — that
    /// stays behind the explicit button, same as before.
    @discardableResult
    public func adoptCacheIfAvailable() -> Bool {
        guard let cached = cachedEntries[Self.overviewCacheKey] else { return false }
        currentDir = nil
        isOverview = true
        entries = cached
        lastScanAt = cachedScanDates[Self.overviewCacheKey]
        if let info = DiskScanner.startupVolumeInfo() {
            volumeName = info.name
        }
        return true
    }

    /// Silently warms the overview cache in the background — used for the
    /// once-a-day launch-time pre-scan. Deliberately does NOT touch
    /// `entries`/`currentDir`/`isScanning`, so it can't clobber whatever the
    /// user is looking at if they open Analyse while this is still running; a
    /// later `scanVolumeOverview()` call just finds the warmed cache and
    /// returns instantly. Runs at `.utility` priority so it yields to whatever
    /// the user is actively doing right after launch. No-ops if the overview
    /// was already scanned earlier today.
    public func preloadOverview() {
        let today = Calendar.current.startOfDay(for: Date())
        if let cachedAt = cachedScanDates[Self.overviewCacheKey], cachedAt >= today {
            return
        }
        // Persisted, not just in-memory: this singleton resets every launch, so
        // without a UserDefaults-backed marker "once a day" would really mean
        // "once per launch" for anyone reopening the app more than once a day.
        let defaults = UserDefaults.standard
        if let lastPreload = defaults.object(forKey: AppStorageKey.analyzeLastPreloadAt) as? Date, lastPreload >= today {
            return
        }
        defaults.set(Date(), forKey: AppStorageKey.analyzeLastPreloadAt)

        Task.detached(priority: .utility) {
            let result = DiskScanner.volumeOverview()
            let scannedAt = Date()
            await MainActor.run {
                guard !result.isEmpty else { return }
                self.cachedEntries[Self.overviewCacheKey] = result
                self.cachedScanDates[Self.overviewCacheKey] = scannedAt
            }
        }
    }
}
