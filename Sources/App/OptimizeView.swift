import SwiftUI
import Core
import Features

struct OptimizeView: View {
    @State private var selectedTasks: Set<String> = []
    // Defaults to actually running — every task in this catalog is a bounded,
    // reversible operation (cache refresh, plist repair, etc.), and defaulting
    // to a no-op preview made "Run Selected" feel broken on first use. Dry Run
    // stays available as an opt-in for anyone who wants to see what a task
    // would do before committing.
    @State private var isDryRun = false
    @State private var running = false
    @State private var results: [String: MaintenanceRunner.Result] = [:]
    @State private var inFlight: Set<String> = []

    private let tint = ContentView.SidebarItem.optimize.tint

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: ContentView.SidebarItem.optimize.icon)
                    .foregroundStyle(tint)
                Text("Maintenance").font(.title2).bold()
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Toggle("Dry Run", isOn: $isDryRun)
                        .toggleStyle(.switch)
                        .disabled(running)
                    Text(isDryRun ? "Preview only — nothing changes" : "Runs for real")
                        .font(.caption2)
                        .foregroundStyle(isDryRun ? Color.blue : Color.secondary)
                }
                Button(running ? "Running..." : "Run Selected") {
                    Task { await runSelected() }
                }
                .disabled(selectedTasks.isEmpty || running)
                .buttonStyle(.borderedProminent)
                .tint(tint)
            }
            .padding()

            Label("All tasks below are bounded and safe to run — myKikau only lists vetted maintenance operations, nothing that could break your Mac.", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            if !results.isEmpty {
                SummaryBanner(results: results)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            List(MaintenanceCatalog.tasks, selection: $selectedTasks) { task in
                TaskRow(
                    task: task,
                    result: results[task.id],
                    inFlight: inFlight.contains(task.id)
                )
                .tag(task.id)
            }
        }
    }

    private func runSelected() async {
        running = true
        let runner = MaintenanceRunner()
        let sorted = MaintenanceCatalog.tasks
            .filter { selectedTasks.contains($0.id) }
            .map { $0.id }

        for id in sorted {
            inFlight.insert(id)
            let result = await runner.run(taskID: id, dryRun: isDryRun)
            results[id] = result
            inFlight.remove(id)
        }

        running = false
    }
}

private struct TaskRow: View {
    let task: MaintenanceCatalog.Task
    let result: MaintenanceRunner.Result?
    let inFlight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.name).font(.body)
                if task.safeForAuto {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("Safe — bounded, reversible, vetted for unattended use")
                }
                if task.requiresSudo {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Needs your admin password to run")
                }
                Spacer()
                if inFlight {
                    ProgressView()
                        .controlSize(.small)
                } else if let result {
                    OutcomeBadge(outcome: result.outcome)
                }
            }
            Text(task.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let result, let detail = result.outcome.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(result.outcome.color)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct OutcomeBadge: View {
    let outcome: MaintenanceOutcome

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: outcome.icon)
            Text(outcome.label)
        }
        .font(.caption)
        .foregroundStyle(outcome.color)
    }
}

private struct SummaryBanner: View {
    let results: [String: MaintenanceRunner.Result]

    var body: some View {
        HStack(spacing: 16) {
            CountBadge(label: "Applied", count: count(.applied(nil)), color: .green)
            CountBadge(label: "No Change", count: count(.unchanged(nil)), color: .secondary)
            CountBadge(label: "Skipped", count: skippedCount, color: .blue)
            CountBadge(label: "Failed", count: count(.failed(nil)), color: .red)
            Spacer()
            Text("\(results.count) task(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func count(_ outcome: MaintenanceOutcome) -> Int {
        results.values.filter { sameCase($0.outcome, outcome) }.count
    }

    private var skippedCount: Int {
        results.values.filter {
            if case .skipped = $0.outcome { return true }
            if case .unavailable = $0.outcome { return true }
            if case .attention = $0.outcome { return true }
            return false
        }.count
    }

    // Compare by case (ignoring associated detail).
    private func sameCase(_ a: MaintenanceOutcome, _ b: MaintenanceOutcome) -> Bool {
        switch (a, b) {
        case (.applied, .applied), (.unchanged, .unchanged), (.failed, .failed):
            return true
        default:
            return false
        }
    }
}

private struct CountBadge: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.body.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(count > 0 ? color : .secondary)
    }
}
