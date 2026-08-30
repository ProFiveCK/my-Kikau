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

    private var timer: Timer?
    private var subscriberCount = 0

    private init() {}

    /// Call once per subscribing view, from `.onAppear`. Safe to call from
    /// multiple views concurrently — only the first subscriber starts the timer.
    public func subscribe() {
        subscriberCount += 1
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
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

    private func refresh() async {
        snapshot = await MetricsCollector.shared.collect()
    }
}
