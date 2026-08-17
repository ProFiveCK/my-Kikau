import Combine
import Foundation
import Core

/// Keeps the last Analyze scan alive while the app is running, even when the
/// user navigates away from the Analyse screen.
@MainActor
public final class AnalyzeScanSession: ObservableObject {
    public static let shared = AnalyzeScanSession()

    @Published public private(set) var entries: [DiskScanner.Entry] = []
    @Published public private(set) var currentDir: URL?
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastScanAt: Date?

    private var cachedEntries: [String: [DiskScanner.Entry]] = [:]
    private var cachedScanDates: [String: Date] = [:]

    private init() {}

    public var hasResults: Bool { !entries.isEmpty }

    public func scan(_ directory: URL, useCache: Bool = true) {
        currentDir = directory
        if useCache, let cached = cachedEntries[directory.path] {
            entries = cached
            lastScanAt = cachedScanDates[directory.path]
            return
        }
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let result = DiskScanner.scan(directory)
            let scannedAt = Date()
            await MainActor.run {
                self.entries = result
                self.cachedEntries[directory.path] = result
                self.cachedScanDates[directory.path] = scannedAt
                self.lastScanAt = scannedAt
                self.isScanning = false
            }
        }
    }

    public func rescanCurrent() {
        scan(currentDir ?? FileManager.default.homeDirectoryForCurrentUser, useCache: false)
    }

    /// Adopts an already-cached scan into the published state if one exists
    /// (e.g. from the launch-time `preload`) — mirrors how `CleanView`/
    /// `UninstallView` adopt `ScanEverythingCoordinator`'s cache on
    /// `.onAppear`. Deliberately does NOT fall back to triggering a fresh
    /// scan when there's no cache: a tab you merely opened should never
    /// silently kick off an expensive disk walk you didn't ask for — that
    /// stays behind the explicit "Scan Home" button, same as before.
    @discardableResult
    public func adoptCacheIfAvailable(for directory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let cached = cachedEntries[directory.path] else { return false }
        currentDir = directory
        entries = cached
        lastScanAt = cachedScanDates[directory.path]
        return true
    }

    /// Silently warms the cache for `directory` in the background — used for
    /// the once-a-day launch-time pre-scan. Deliberately does NOT touch
    /// `entries`/`currentDir`/`isScanning`, so it can't clobber whatever the
    /// user is actually looking at if they open Analyse while this is still
    /// running; a later `scan(directory)` call just finds the warmed cache
    /// and returns instantly instead of re-scanning. Runs at `.utility`
    /// priority (below the `.userInitiated` a real button tap gets) so it
    /// yields to whatever the user is actively doing right after launch.
    /// No-ops if `directory` was already scanned earlier today.
    public func preload(_ directory: URL) {
        let today = Calendar.current.startOfDay(for: Date())
        if let cachedAt = cachedScanDates[directory.path], cachedAt >= today {
            return
        }
        // Persisted, not just in-memory: this singleton resets every launch,
        // so without a UserDefaults-backed marker "once a day" would really
        // mean "once per launch" for anyone reopening the app more than once
        // in a day.
        let defaults = UserDefaults.standard
        if let lastPreload = defaults.object(forKey: AppStorageKey.analyzeLastPreloadAt) as? Date, lastPreload >= today {
            return
        }
        defaults.set(Date(), forKey: AppStorageKey.analyzeLastPreloadAt)

        Task.detached(priority: .utility) {
            let result = DiskScanner.scan(directory)
            let scannedAt = Date()
            await MainActor.run {
                self.cachedEntries[directory.path] = result
                self.cachedScanDates[directory.path] = scannedAt
            }
        }
    }
}
