import Foundation

public enum AppStorageKey {
    public static let showDockIcon = "myKikau.showDockIcon"
    public static let didCompleteOnboarding = "myKikau.didCompleteOnboarding"
    public static let libraryBookmarks = "myKikau.libraryBookmarks"
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
}
