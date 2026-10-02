import Foundation

public enum AppStorageKey {
    public static let showDockIcon = "myKikau.showDockIcon"
    public static let didCompleteOnboarding = "myKikau.didCompleteOnboarding"
    /// Set the first time the user opens Analyse. Gates the launch-time
    /// background disk scan preload — no point pre-scanning for someone who's
    /// never looked at that screen.
    public static let hasUsedAnalyze = "myKikau.hasUsedAnalyze"
    /// Timestamp of the last launch-time Analyze preload. Stored in
    /// `UserDefaults` directly (not just in-memory) because `AnalyzeScanSession`
    /// resets every launch — without a persisted marker, "once a day" would
    /// silently become "once per launch" for anyone who reopens the app more
    /// than once in a day.
    public static let analyzeLastPreloadAt = "myKikau.analyzeLastPreloadAt"
    /// Paths the user has told myKikau never to delete (Settings → Exclusions).
    public static let userExclusions = "myKikau.userExclusions"
    /// Whether file operations are written to the operation log.
    public static let operationLogEnabled = "myKikau.operationLogEnabled"
    /// Last sidebar screen, restored on launch.
    public static let lastSidebarSelection = "myKikau.lastSidebarSelection"
    /// Shows developer-oriented features (the project build-artifact purge).
    public static let developerToolsEnabled = "myKikau.developerToolsEnabled"
    /// Extra folders the Files scan covers, beyond the defaults.
    public static let fileScanFolders = "myKikau.fileScanFolders"
    /// Minimum size, in megabytes, for the Large Files list.
    public static let largeFileThresholdMB = "myKikau.largeFileThresholdMB"
    /// Hours between background scans; 0 disables them.
    public static let scheduledScanIntervalHours = "myKikau.scheduledScanIntervalHours"
    /// Post a notification when a background scan finds this many bytes or more.
    public static let notifyReclaimableThresholdMB = "myKikau.notifyReclaimableThresholdMB"
    public static let lastScheduledScanAt = "myKikau.lastScheduledScanAt"
}
