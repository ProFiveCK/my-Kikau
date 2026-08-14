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
    @State private var lastRuns: [String: MaintenanceRunStatus] = [:]

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

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(MaintenanceCatalog.tasks) { task in
                        MaintenanceTaskCard(
                            task: task,
                            selected: selectedTasks.contains(task.id),
                            result: results[task.id],
                            lastRun: lastRuns[task.id],
                            inFlight: inFlight.contains(task.id)
                        ) {
                            if selectedTasks.contains(task.id) {
                                selectedTasks.remove(task.id)
                            } else {
                                selectedTasks.insert(task.id)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear { reloadLastRuns() }
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
            lastRuns[id] = MaintenanceRunStatus(
                timestamp: Date(),
                outcome: result.outcome.label,
                detail: result.outcome.detail,
                dryRun: isDryRun
            )
            inFlight.remove(id)
        }

        running = false
    }

    private func reloadLastRuns() {
        let prefix = "optimize."
        var statuses: [String: MaintenanceRunStatus] = [:]
        for entry in OperationLog.shared.recent(limit: 10_000) where entry.action.hasPrefix(prefix) {
            let id = String(entry.action.dropFirst(prefix.count))
            guard statuses[id] == nil else { continue }
            statuses[id] = MaintenanceRunStatus(
                timestamp: entry.timestamp,
                outcome: entry.outcome.displayLabel,
                detail: entry.detail,
                dryRun: entry.dryRun
            )
        }
        lastRuns = statuses
    }
}

private struct MaintenanceRunStatus: Hashable {
    let timestamp: Date
    let outcome: String
    let detail: String?
    let dryRun: Bool
}

private struct MaintenanceTaskCard: View {
    let task: MaintenanceCatalog.Task
    let selected: Bool
    let result: MaintenanceRunner.Result?
    let lastRun: MaintenanceRunStatus?
    let inFlight: Bool
    let onToggle: () -> Void

    private var category: (label: String, icon: String, color: Color) {
        switch task.id {
        case "finder_cache", "launch_services", "shared_file_lists":
            return ("Finder", "sparkles.rectangle.stack", .blue)
        case "saved_state", "quarantine":
            return ("Privacy", "clock.arrow.circlepath", .purple)
        case "broken_configs", "legacy_overrides", "spotlight_orphans":
            return ("Repair", "wrench.and.screwdriver", .orange)
        case "prevent_dsstore", "launch_agents":
            return ("Startup", "bolt.horizontal.circle", .green)
        default:
            return ("Maintenance", "checkmark.shield", .secondary)
        }
    }

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(category.color.opacity(0.16))
                            .frame(width: 38, height: 38)
                        Image(systemName: category.icon)
                            .foregroundStyle(category.color)
                            .font(.system(size: 16, weight: .semibold))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(category.label)
                            .font(.caption2.bold())
                            .foregroundStyle(category.color)
                    }

                    Spacer()

                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? tintColor : .secondary)
                }

                Text(task.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(minHeight: 44, alignment: .topLeading)

                HStack(spacing: 8) {
                    if inFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else if let result {
                        OutcomeBadge(outcome: result.outcome)
                    } else if let lastRun {
                        Label(lastRun.outcome, systemImage: "clock")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Ready", systemImage: "play.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if task.safeForAuto {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .help("Safe — bounded, reversible, vetted for unattended use")
                    }
                    if task.requiresSudo {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                            .help("Needs your admin password to run")
                    }
                }
                .font(.caption)

                if let lastRun {
                    Text("Last run \(lastRun.timestamp.formatted(date: .abbreviated, time: .shortened))\(lastRun.dryRun ? " · dry run" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("Never run")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let result, let detail = result.outcome.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(result.outcome.color)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? tintColor.opacity(0.7) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var tintColor: Color { ContentView.SidebarItem.optimize.tint }
}

private extension OperationLog.Outcome {
    var displayLabel: String {
        switch self {
        case .success: "Applied"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .dryRun: "Dry Run"
        }
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
