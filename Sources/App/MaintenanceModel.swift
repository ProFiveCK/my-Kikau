import Foundation
import Core
import Features

/// Long-lived maintenance work; results and choices belong to the shared scan.
@MainActor
final class MaintenanceModel: ObservableObject {
    static let shared = MaintenanceModel()
    @Published private(set) var isScanning = false
    @Published private(set) var applying = false
    @Published private(set) var inFlight: Set<String> = []
    private var task: Task<Void, Never>?

    func scan() {
        guard let lease = WorkCoordinator.shared.begin("Checking system care", cancel: { [weak self] in self?.task?.cancel() })
        else { return }
        isScanning = true
        task = Task {
            defer { isScanning = false; inFlight = []; task = nil; WorkCoordinator.shared.finish(lease) }
            let work = Task.detached(priority: .userInitiated) {
                let runner = MaintenanceRunner()
                var results: [String: MaintenanceRunner.Result] = [:]
                for task in MaintenanceCatalog.tasks {
                    if Task.isCancelled {
                        return (results, runner.networkPrivacyReport)
                    }
                    results[task.id] = await runner.run(taskID: task.id, dryRun: true)
                }
                return (results, runner.networkPrivacyReport)
            }
            let (results, privacy) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            let coordinator = ScanEverythingCoordinator.shared
            if let privacy {
                coordinator.setSystemHealthReport(privacy)
            } else if let diagnostic = results["network_privacy"], diagnostic.outcome.isIncomplete {
                coordinator.setSystemHealthScanError(diagnostic.outcome.detail ?? "Privacy check unavailable")
            }
            coordinator.setMaintenanceResults(results)
        }
    }

    func applySelected() {
        guard let lease = WorkCoordinator.shared.begin(
            "Applying system care",
            kind: .maintenance,
            cancel: { [weak self] in self?.task?.cancel() }
        ) else { return }
        let coordinator = ScanEverythingCoordinator.shared
        let ids = MaintenanceCatalog.tasks.filter { $0.kind == .maintenance && coordinator.selectedMaintenanceTasks.contains($0.id)
            && coordinator.maintenanceResults?[$0.id]?.outcome.needsAction == true
        }.map(\.id)
        applying = true
        task = Task {
            defer { applying = false; inFlight = []; task = nil; WorkCoordinator.shared.finish(lease) }
            for id in ids {
                guard !Task.isCancelled else { break }
                inFlight.insert(id)
                let reviewed = Set(coordinator.maintenanceResults?[id]?.output ?? [])
                let work = Task.detached(priority: .userInitiated) {
                    await MaintenanceRunner().run(taskID: id, dryRun: false, reviewedPaths: reviewed)
                }
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                coordinator.maintenanceApplyResults[id] = result
                // Recheck without overwriting what actually ran.
                let check = await Task.detached(priority: .userInitiated) {
                    await MaintenanceRunner().run(taskID: id, dryRun: true)
                }.value
                var checks = coordinator.maintenanceResults ?? [:]
                checks[id] = check
                let applied = coordinator.maintenanceApplyResults
                coordinator.setMaintenanceResults(checks)
                coordinator.maintenanceApplyResults = applied
                if !check.outcome.needsAction {
                    coordinator.selectedMaintenanceTasks.remove(id)
                }
                inFlight.remove(id)
            }
            AnalyzeScanSession.shared.markStale()
        }
    }
}
