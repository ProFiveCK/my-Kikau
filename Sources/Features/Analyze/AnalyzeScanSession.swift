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

    private init() {}

    public var hasResults: Bool { !entries.isEmpty }

    public func scan(_ directory: URL) {
        currentDir = directory
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let result = DiskScanner.scan(directory)
            await MainActor.run {
                self.entries = result
                self.lastScanAt = Date()
                self.isScanning = false
            }
        }
    }
}
