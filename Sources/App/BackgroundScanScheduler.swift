import AppKit
import Foundation
import UserNotifications
import Core
import Features

/// Runs a quick scan on a schedule while myKikau is running (it lives in the
/// menu bar, so that's most of the time) and posts a notification when
/// there's enough to reclaim to be worth a look, or when the startup disk is
/// nearly full.
///
/// A background scan only measures. Nothing is ever removed without the user
/// reviewing it.
@MainActor
final class BackgroundScanScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BackgroundScanScheduler()

    /// How often to check whether a scan is due.
    private static let checkInterval: TimeInterval = 15 * 60
    /// Warn when less than this fraction of the startup disk is free.
    private static let lowDiskFraction = 0.10
    private static let lowDiskNotifiedKey = "myKikau.lowDiskNotifiedAt"

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    /// Hours between scans: the administrator's value if there is one,
    /// otherwise the user's. 0 = off.
    var intervalHours: Int {
        ManagedPolicy.shared.scheduledScanIntervalHours
            ?? defaults.integer(forKey: AppStorageKey.scheduledScanIntervalHours)
    }

    /// `UNUserNotificationCenter` needs a real app bundle; a bare `swift run`
    /// binary has none and would crash on first use.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func start() {
        if notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
        reschedule()
    }

    func reschedule() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer.tolerance = 120
        self.timer = timer
    }

    func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func tick() async {
        checkLowDisk()

        let hours = intervalHours
        guard hours > 0 else { return }
        let coordinator = ScanEverythingCoordinator.shared
        guard !WorkCoordinator.shared.isBusy else { return }
        let last = defaults.object(forKey: AppStorageKey.lastScheduledScanAt) as? Date ?? .distantPast
        // Also counts a scan the user ran by hand.
        let mostRecent = max(last, coordinator.lastScanAt ?? .distantPast)
        guard Date().timeIntervalSince(mostRecent) >= Double(hours) * 3600 else { return }

        defaults.set(Date(), forKey: AppStorageKey.lastScheduledScanAt)
        let previousScan = coordinator.lastScanAt
        let previousCleanup = coordinator.scannedAt[.clean]
        await coordinator.scanEverything(mode: .quick)
        guard coordinator.lastScanAt != previousScan, coordinator.scannedAt[.clean] != previousCleanup else { return }

        let stored = defaults.integer(forKey: AppStorageKey.notifyReclaimableThresholdMB)
        let thresholdMB = stored > 0 ? stored : 2000
        let reclaimable = coordinator.cleanPlans?.values.reduce(Int64(0)) { $0 + $1.totalReclaimable } ?? 0
        if reclaimable >= Int64(thresholdMB) * 1_000_000 {
            post(
                id: "scan-result",
                title: "\(ByteSizeFormatter.format(reclaimable)) can be reclaimed",
                body: "Open myKikau to review what the scan found. Nothing has been removed."
            )
        }
    }

    private func checkLowDisk() {
        guard let info = DiskScanner.startupVolumeInfo(), info.totalBytes > 0 else { return }
        let freeFraction = Double(info.freeBytes) / Double(info.totalBytes)
        guard freeFraction < Self.lowDiskFraction else { return }
        // At most once a day.
        let last = defaults.object(forKey: Self.lowDiskNotifiedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86400 else { return }
        defaults.set(Date(), forKey: Self.lowDiskNotifiedKey)
        post(
            id: "low-disk",
            title: "\(info.name) is almost full",
            body: "\(ByteSizeFormatter.format(info.freeBytes)) free. Open myKikau to see what can be cleared."
        )
    }

    private func post(id: String, title: String, body: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Clicking the notification brings the app forward on the dashboard.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NSApplication.shared.activate(ignoringOtherApps: true)
            AppNavigation.shared.pendingSelection = .status
        }
        completionHandler()
    }
}
