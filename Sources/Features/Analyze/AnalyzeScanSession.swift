import Combine
import Foundation

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
}
