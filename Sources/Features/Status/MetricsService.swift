import Foundation

/// Shared, single-timer source of truth for live system metrics.
///
/// Before this existed, `StatusView` and the menu bar `HUDView` each ran their
/// own independent 2-second `Timer` calling `MetricsCollector.shared.collect()`
/// — duplicate work, and the two views' numbers could drift out of sync by up
/// to a tick. Both now subscribe to this instead; the underlying poll runs
/// once no matter how many views are on screen.
@MainActor
public final class MetricsService: ObservableObject {
    public static let shared = MetricsService()

    @Published public private(set) var snapshot: MetricsSnapshot?
    /// Recent CPU and memory readings, oldest first, for trend lines — about
    /// the last five minutes while something is subscribed.
    @Published public private(set) var history: [Sample] = []

    public struct Sample: Identifiable, Sendable {
        public let id: Int
        public let cpuPercent: Double
        public let memoryPercent: Double
    }

    private static let historyLimit = 150
    private var sampleCounter = 0

    private var timer: Timer?
    private var subscriberCount = 0
    private var isRefreshing = false

    private init() {}

    /// Call once per subscribing view, from `.onAppear`. Safe to call from
    /// multiple views concurrently — only the first subscriber starts the timer.
    public func subscribe() {
        subscriberCount += 1
        guard timer == nil else { return }
        Task { await refresh() }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // Let macOS coalesce the wake-up with other timers.
        timer.tolerance = 0.4
        self.timer = timer
    }

    /// Pairs with `subscribe()`, call from `.onDisappear`. The timer stops once
    /// the last subscriber unsubscribes, so it doesn't keep polling with no
    /// views on screen (e.g. main window closed, only the pinned menu bar icon left).
    public func unsubscribe() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// One collection at a time: `MetricsCollector` diffs each sample against
    /// the previous one, so a slow tick must finish before the next starts.
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let latest = await MetricsCollector.shared.collect()
        snapshot = latest
        sampleCounter += 1
        // The very first sample has no previous CPU reading to diff against.
        if sampleCounter > 1 {
            history.append(Sample(id: sampleCounter, cpuPercent: latest.cpu.usage, memoryPercent: latest.memory.usedPercent))
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
    }
}
