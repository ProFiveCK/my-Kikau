import SwiftUI
import Core
import Features

/// Maintenance, redesigned around a scan-first flow: instead of a flat grid
/// of technical checkboxes with no signal on which ones actually matter, a
/// scan runs every task in dry-run mode (which already reports exactly what
/// each task would do, at no extra cost — `MaintenanceRunner` was always
/// capable of this, it just wasn't surfaced as a recommendation step) and
/// splits results into "Recommended" (found something to fix, pre-selected)
/// vs. "Already Optimised" (nothing to do). One button then applies the
/// recommended set for real.
struct OptimizeView: View {
    private enum ScanState { case notScanned, scanning, scanned }

    @State private var scanState: ScanState = .notScanned
    @State private var scanResults: [String: MaintenanceRunner.Result] = [:]
    @State private var applyResults: [String: MaintenanceRunner.Result] = [:]
    @State private var selectedTasks: Set<String> = []
    @State private var applying = false
    @State private var inFlight: Set<String> = []
    @State private var lastRuns: [String: MaintenanceRunStatus] = [:]

    private let tint = ContentView.SidebarItem.optimize.tint

    private var recommendedTasks: [MaintenanceCatalog.Task] {
        MaintenanceCatalog.tasks.filter { isRecommended($0.id) }
    }

    private var cleanTasks: [MaintenanceCatalog.Task] {
        MaintenanceCatalog.tasks.filter { !isRecommended($0.id) }
    }

    private func isRecommended(_ taskID: String) -> Bool {
        if case .applied = scanResults[taskID]?.outcome { return true }
        return false
    }

    private var headerSubtitle: String {
        switch scanState {
        case .notScanned:
            return "\(MaintenanceCatalog.tasks.count) safe, reversible checks — caches, broken prefs, stale agents"
        case .scanning:
            return "Checking your Mac…"
        case .scanned:
            return recommendedTasks.isEmpty
                ? "Nothing to fix — your Mac's maintenance is up to date"
                : "\(recommendedTasks.count) issue\(recommendedTasks.count == 1 ? "" : "s") found"
        }
    }

    private var scanButtonTitle: String {
        switch scanState {
        case .notScanned: return "Scan for Issues"
        case .scanning: return "Scanning…"
        case .scanned: return "Rescan"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: ContentView.SidebarItem.optimize.icon)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Optimise").font(.title2).bold()
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(scanState == .scanned && !recommendedTasks.isEmpty ? tint : .secondary)
                }
                Spacer()
                if scanState == .scanned && !recommendedTasks.isEmpty {
                    Button(applying ? "Fixing…" : "Fix \(selectedTasks.count) Issue\(selectedTasks.count == 1 ? "" : "s")") {
                        Task { await applySelected() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .disabled(selectedTasks.isEmpty || applying)
                }
                if scanState == .scanned {
                    Button(scanButtonTitle) { Task { await runScan() } }
                        .buttonStyle(.bordered)
                        .tint(tint)
                        .disabled(scanState == .scanning || applying)
                } else {
                    Button(scanButtonTitle) { Task { await runScan() } }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                        .disabled(scanState == .scanning || applying)
                }
            }
            .padding()

            Label("All tasks below are bounded and safe to run — myKikau only lists vetted maintenance operations, nothing that could break your Mac.", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            switch scanState {
            case .notScanned:
                ContentUnavailableView(
                    "Scan to Find Issues",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("Checks \(MaintenanceCatalog.tasks.count) safe, reversible maintenance tasks — broken preferences, stale caches, orphaned launch agents — and recommends exactly what to fix.")
                )
            case .scanning:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking \(MaintenanceCatalog.tasks.count) maintenance tasks…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanned:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !applyResults.isEmpty {
                            SummaryBanner(results: applyResults)
                        }

                        if recommendedTasks.isEmpty {
                            AllClearBanner()
                        } else {
                            TaskSection(
                                title: "Recommended",
                                subtitle: "\(recommendedTasks.count) issue\(recommendedTasks.count == 1 ? "" : "s") found",
                                color: tint
                            ) {
                                taskGrid(recommendedTasks)
                            }
                        }

                        if !cleanTasks.isEmpty {
                            TaskSection(title: "Already Optimised", subtitle: "No issues found", color: .secondary) {
                                taskGrid(cleanTasks)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear { reloadLastRuns() }
    }

    private func taskGrid(_ tasks: [MaintenanceCatalog.Task]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
            ForEach(tasks) { task in
                MaintenanceTaskCard(
                    task: task,
                    selected: selectedTasks.contains(task.id),
                    result: applyResults[task.id] ?? scanResults[task.id],
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
    }

    /// Runs every catalog task in dry-run mode — `MaintenanceRunner` already
    /// reports `.applied("Would …")` when a task finds something to fix and
    /// `.unchanged(...)` when it doesn't, so this dry-run pass doubles as the
    /// scan/recommendation step with no separate detection logic needed.
    private func runScan() async {
        scanState = .scanning
        scanResults = [:]
        applyResults = [:]
        selectedTasks = []
        let runner = MaintenanceRunner()
        for task in MaintenanceCatalog.tasks {
            inFlight.insert(task.id)
            let result = await runner.run(taskID: task.id, dryRun: true)
            scanResults[task.id] = result
            if case .applied = result.outcome {
                selectedTasks.insert(task.id)
            }
            inFlight.remove(task.id)
        }
        scanState = .scanned
    }

    private func applySelected() async {
        applying = true
        let runner = MaintenanceRunner()
        let ids = MaintenanceCatalog.tasks.map(\.id).filter { selectedTasks.contains($0) }
        for id in ids {
            inFlight.insert(id)
            let result = await runner.run(taskID: id, dryRun: false)
            applyResults[id] = result
            lastRuns[id] = MaintenanceRunStatus(
                timestamp: Date(),
                outcome: result.outcome.label,
                detail: result.outcome.detail,
                dryRun: false
            )
            inFlight.remove(id)
        }
        applying = false
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

/// Section grouping for the scanned state — "Recommended" vs. "Already
/// Optimised" — with a small colored count badge instead of a plain heading,
/// so the recommendation reads as a recommendation and not just a category label.
private struct TaskSection<Content: View>: View {
    let title: String
    let subtitle: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())
            }
            content
        }
    }
}

private struct AllClearBanner: View {
    var body: some View {
        Label("Your Mac's maintenance is up to date — nothing needs fixing right now.", systemImage: "checkmark.seal.fill")
            .font(.subheadline)
            .foregroundStyle(.green)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
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
