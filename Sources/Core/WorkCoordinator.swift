import Combine
import Foundation

/// One owner for disk discovery, maintenance and destructive work in the app.
/// A cancelled job keeps its lease until its worker has actually stopped.
@MainActor
public final class WorkCoordinator: ObservableObject {
    public static let shared = WorkCoordinator()
    public enum Kind: Sendable { case scan, maintenance, deletion, updates }
    public struct Activity: Identifiable {
        public let id: UUID
        public let title: String
        public let kind: Kind
    }

    @Published public private(set) var activity: Activity?
    private var cancellation: (() -> Void)?
    public init() {}
    public var isBusy: Bool {
        activity != nil
    }

    @discardableResult
    public func begin(_ title: String, kind: Kind = .scan, cancel: (() -> Void)? = nil) -> UUID? {
        guard activity == nil else { return nil }
        let id = UUID()
        cancellation = cancel
        activity = Activity(id: id, title: title, kind: kind)
        return id
    }

    public func setCancellation(_ cancel: @escaping () -> Void, for id: UUID) {
        guard activity?.id == id else { return }
        cancellation = cancel
    }

    public var canCancel: Bool {
        cancellation != nil
    }

    public func cancel() {
        cancellation?()
    }

    public func finish(_ id: UUID) {
        guard activity?.id == id else { return }
        cancellation = nil
        activity = nil
    }
}
