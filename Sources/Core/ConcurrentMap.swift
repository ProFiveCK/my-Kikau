import Foundation

/// Maps `items` on several threads at once, preserving order.
///
/// For CPU- or disk-bound work on a handful of independent inputs (measuring
/// each app bundle, each top-level folder). Blocks until every element is
/// done, so call it off the main thread.
public func concurrentMap<Input: Sendable, Output: Sendable>(
    _ items: [Input],
    _ transform: @Sendable (Input) -> Output
) -> [Output] {
    guard !items.isEmpty else { return [] }
    let slots = Slots<Output>(count: items.count)
    DispatchQueue.concurrentPerform(iterations: items.count) { index in
        slots.set(index, transform(items[index]))
    }
    return slots.values()
}

/// One slot per input. Each iteration writes only its own index, so the
/// writes never overlap; the lock makes that safe to state to the compiler.
private final class Slots<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value?]

    init(count: Int) {
        storage = [Value?](repeating: nil, count: count)
    }

    func set(_ index: Int, _ value: Value) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    func values() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { $0 }
    }
}
