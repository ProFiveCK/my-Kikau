import Foundation
import Core
import Features

@MainActor
final class StartupModel: ObservableObject {
    static let shared = StartupModel()
    @Published private(set) var loading = false
    private var task: Task<Void, Never>?
    func scan() {
        guard let lease = WorkCoordinator.shared.begin("Reading startup items", cancel: { [weak self] in self?.task?.cancel() })
        else { return }
        loading = true
        task = Task {
            defer { loading = false; task = nil; WorkCoordinator.shared.finish(lease) }
            let coverage = ScanCoverageRecorder()
            let work = Task.detached(priority: .userInitiated) { StartupItems.scan(coverage: coverage) }
            let items = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            ScanEverythingCoordinator.shared.setStartupItems(items, coverage: coverage.snapshot)
        }
    }
}
