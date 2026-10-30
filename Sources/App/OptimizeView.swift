import AppKit
import SwiftUI
import Core
import Features
import UI

/// One sidebar entry for maintenance checks and the startup items, the way
/// CleanMyMac keeps both under Performance. Each part keeps its own policy key.
struct SystemCareView: View {
    enum Part: String, CaseIterable, Identifiable {
        case maintenance = "Maintenance"
        case startup = "Startup items"
        var id: String {
            rawValue
        }

        static var available: [Part] {
            allCases.filter { !ManagedPolicy.shared.isFeatureDisabled($0 == .maintenance ? "optimize" : "startup") }
        }
    }

    @State private var part: Part = .maintenance

    var body: some View {
        let parts = Part.available
        let picker = parts.count > 1 ? $part : nil
        switch parts.contains(part) ? part : parts.first ?? .maintenance {
        case .maintenance: OptimizeView(part: picker)
        case .startup: StartupView(part: picker)
        }
    }
}

/// The Maintenance / Startup items switch, shown in either part's header.
struct SystemCarePartPicker: View {
    @Binding var part: SystemCareView.Part

    var body: some View {
        Picker("Show", selection: $part) {
            ForEach(SystemCareView.Part.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

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

    /// Set when System care shows both parts.
    var part: Binding<SystemCareView.Part>?

    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var model = MaintenanceModel.shared
    @ObservedObject private var activity = WorkCoordinator.shared
    private var scanState: ScanState {
        model.isScanning || coordinator.isScanning ? .scanning : coordinator.maintenanceResults == nil ? .notScanned : .scanned
    }

    private var scanResults: [String: MaintenanceRunner.Result] {
        get { coordinator.maintenanceResults ?? [:] }
        nonmutating set { coordinator.setMaintenanceResults(newValue) }
    }

    private var applyResults: [String: MaintenanceRunner.Result] {
        coordinator.maintenanceApplyResults
    }

    private var selectedTasks: Set<String> {
        get { coordinator.selectedMaintenanceTasks }
        nonmutating set { coordinator.selectedMaintenanceTasks = newValue }
    }

    private var applying: Bool {
        model.applying
    }

    private var inFlight: Set<String> {
        model.inFlight
    }

    @State private var guidedTask: MaintenanceCatalog.Task?
    @State private var confirmingFix = false

    private let tint = ContentView.SidebarItem.optimize.tint

    private var recommendedTasks: [MaintenanceCatalog.Task] {
        MaintenanceCatalog.tasks.filter { isRecommended($0.id) }
    }

    private var cleanTasks: [MaintenanceCatalog.Task] {
        MaintenanceCatalog.tasks.filter { scanResults[$0.id]?.outcome.isClear == true }
    }

    private var informationalTasks: [MaintenanceCatalog.Task] {
        MaintenanceCatalog.tasks.filter { isInformational($0.id) }
    }

    private func isInformational(_ taskID: String) -> Bool {
        if case .information = scanResults[taskID]?.outcome {
            return true
        }
        return false
    }

    private var incompleteTasks: [MaintenanceCatalog.Task] {
        MaintenanceCatalog.tasks.filter { scanResults[$0.id] == nil || scanResults[$0.id]?.outcome.isIncomplete == true }
    }

    private func isRecommended(_ taskID: String) -> Bool {
        scanResults[taskID]?.outcome.needsAction == true
    }

    private var headerSubtitle: String {
        switch scanState {
        case .notScanned:
            "\(MaintenanceCatalog.tasks.count) safe, reversible checks — caches, broken prefs, stale agents"
        case .scanning:
            "Checking your Mac…"
        case .scanned:
            !incompleteTasks.isEmpty
                ? "\(recommendedTasks.count) recommendation\(recommendedTasks.count == 1 ? "" : "s") · \(incompleteTasks.count) check\(incompleteTasks.count == 1 ? "" : "s") incomplete"
                : recommendedTasks.isEmpty ? "No maintenance changes recommended" : "\(recommendedTasks.count) recommendations to review"
        }
    }

    private var scanButtonTitle: String {
        switch scanState {
        case .notScanned: "Scan for Issues"
        case .scanning: "Scanning…"
        case .scanned: "Rescan"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("System care", subtitle: headerSubtitle, systemImage: ContentView.SidebarItem.optimize.icon, tint: tint) {
                if let part {
                    SystemCarePartPicker(part: part)
                }
                if scanState == .scanned, !selectedTasks.isEmpty {
                    Button(applying ? "Applying…" : "Review \(selectedTasks.count) Recommendation\(selectedTasks.count == 1 ? "" : "s")…") {
                        confirmingFix = true
                    }
                    .carePrimaryAction()
                    .tint(tint)
                    .disabled(selectedTasks.isEmpty || activity.isBusy)
                }
                if scanState == .scanned {
                    Button(scanButtonTitle) { model.scan() }
                        .keyboardShortcut("r", modifiers: .command)
                        .buttonStyle(.bordered)
                        .tint(tint)
                        .disabled(activity.isBusy)
                } else {
                    Button(scanButtonTitle) { model.scan() }
                        .carePrimaryAction()
                        .tint(tint)
                        .disabled(activity.isBusy)
                }
            }

            switch scanState {
            case .notScanned:
                CareEmptyState(
                    "Scan to Find Issues",
                    systemImage: "wrench.and.screwdriver",
                    description: Text(
                        "Checks \(MaintenanceCatalog.tasks.count) safe, reversible maintenance tasks — broken preferences, "
                            + "stale caches, orphaned launch agents — and recommends exactly what to fix."
                    )
                ) {
                    Button(scanButtonTitle) { model.scan() }.carePrimaryAction().disabled(activity.isBusy)
                }
            case .scanning:
                ScanProgressBar(
                    coordinator.isScanning ? (coordinator.phase?.label ?? "Scanning your Mac…")
                        : "Checking \(MaintenanceCatalog.tasks.count) maintenance tasks",
                    detail: "Inspection only. Nothing is changed until you review the recommendations.",
                    onCancel: activity.canCancel ? { activity.cancel() } : nil
                )
                .padding(.horizontal).padding(.bottom, 8)
                Spacer()
            case .scanned:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if recommendedTasks.isEmpty, incompleteTasks.isEmpty {
                            AllClearBanner()
                        } else if !recommendedTasks.isEmpty {
                            TaskSection(
                                title: "Recommended",
                                subtitle: "\(recommendedTasks.count) recommendation\(recommendedTasks.count == 1 ? "" : "s")",
                                color: tint
                            ) {
                                taskGrid(recommendedTasks)
                            }
                        }

                        if !informationalTasks.isEmpty {
                            TaskSection(title: "Information", subtitle: "No repair needed", color: .blue) {
                                taskGrid(informationalTasks)
                            }
                        }

                        if !incompleteTasks.isEmpty {
                            TaskSection(title: "Couldn’t complete", subtitle: "These checks are not an all-clear", color: .orange) {
                                taskGrid(incompleteTasks)
                            }
                        }
                        if !cleanTasks.isEmpty {
                            // Collapsed: a check with nothing to do needs no attention.
                            DisclosureGroup("\(cleanTasks.count) check\(cleanTasks.count == 1 ? "" : "s") with nothing to do") {
                                taskGrid(cleanTasks).padding(.top, 8)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
            }
        }
        .careScreen()
        .sheet(item: $guidedTask) { task in
            NetworkPrivacyReviewSheet(initialReport: ScanEverythingCoordinator.shared.systemHealthReport) { report in
                scanResults[task.id] = .init(outcome: MaintenanceRunner().networkPrivacyOutcome(for: report))
                ScanEverythingCoordinator.shared.setSystemHealthReport(report)
            }
        }
        .sheet(isPresented: $confirmingFix) {
            FixConfirmationSheet(
                tasks: MaintenanceCatalog.tasks.filter { selectedTasks.contains($0.id) },
                scanResults: scanResults,
                onCancel: { confirmingFix = false },
                onConfirm: {
                    confirmingFix = false
                    model.applySelected()
                }
            )
        }
    }

    private func taskGrid(_ tasks: [MaintenanceCatalog.Task]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
            ForEach(tasks) { task in
                MaintenanceTaskCard(
                    task: task,
                    selectable: isRecommended(task.id),
                    selected: selectedTasks.contains(task.id),
                    result: applyResults[task.id] ?? scanResults[task.id],
                    inFlight: inFlight.contains(task.id)
                ) {
                    if task.kind == .guidedDiagnostic {
                        guidedTask = task
                    } else if !isRecommended(task.id) {
                        return
                    } else if selectedTasks.contains(task.id) {
                        selectedTasks.remove(task.id)
                    } else {
                        selectedTasks.insert(task.id)
                    }
                }
            }
        }
    }
}

/// What "Fix" is about to do, spelled out: each selected task, and — for the
/// ones that move files to the Trash — exactly which files.
private struct FixConfirmationSheet: View {
    let tasks: [MaintenanceCatalog.Task]
    let scanResults: [String: MaintenanceRunner.Result]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var fileCount: Int {
        tasks.reduce(0) { $0 + (scanResults[$1.id]?.output.count ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            CareWindowHeader(
                "Review \(tasks.count) Recommendation\(tasks.count == 1 ? "" : "s")",
                subtitle: fileCount > 0
                    ? "\(fileCount) file\(fileCount == 1 ? "" : "s") will move to the Trash, where you can put them back. Everything else is a setting or cache macOS rebuilds."
                    : "These refresh settings and caches that macOS rebuilds on its own. No files are removed."
            ) { EmptyView() }

            Divider()

            List {
                ForEach(tasks) { task in
                    Section {
                        if let detail = scanResults[task.id]?.outcome.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.subheadline)
                        }
                        ForEach(scanResults[task.id]?.output ?? [], id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .help(path)
                            .contextMenu { PathMenu(url: url) }
                        }
                    } header: {
                        Text(task.name)
                    } footer: {
                        Text(task.summary)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Fix", action: onConfirm)
                    .carePrimaryAction()
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
        .careScreen()
    }
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
    /// Only a recommendation can be ticked; other cards show no checkbox.
    let selectable: Bool
    let selected: Bool
    let result: MaintenanceRunner.Result?
    let inFlight: Bool
    let onToggle: () -> Void

    private var category: (label: String, icon: String, color: Color) {
        switch task.id {
        case "finder_cache", "launch_services", "shared_file_lists":
            ("Finder", "sparkles.rectangle.stack", .blue)
        case "saved_state":
            ("Privacy", "clock.arrow.circlepath", .purple)
        case "broken_configs", "legacy_overrides", "font_cache":
            ("Repair", "wrench.and.screwdriver", .orange)
        case "prevent_dsstore", "launch_agents":
            ("Startup", "bolt.horizontal.circle", .green)
        case "network_privacy":
            ("System", "info.circle", .blue)
        default:
            ("Maintenance", "checkmark.shield", .secondary)
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

                    if task.kind == .guidedDiagnostic {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(category.color)
                    } else if selectable {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(selected ? tintColor : .secondary)
                    }
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
                    } else {
                        Label("Not checked", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if task.safeForAuto {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .help("Safe — bounded, reversible, vetted for unattended use")
                    }
                    if task.kind == .guidedDiagnostic {
                        Label("Review", systemImage: "info.circle")
                            .foregroundStyle(.blue)
                            .help("Review privacy settings and ignore informational items; never included in Fix All")
                    }
                    if task.requiresSudo {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                            .help("Needs your admin password to run")
                    }
                }
                .font(.caption)

                if let result, let detail = result.outcome.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(result.outcome.color)
                        .lineLimit(2)
                }
                if let result, !result.output.isEmpty {
                    Text("\(result.output.count) file\(result.output.count == 1 ? "" : "s") — listed before anything is changed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .cardSurface(radius: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? tintColor.opacity(0.7) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(task.name). \(task.summary)")
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        var parts: [String] = []
        if let result {
            parts.append(result.outcome.label)
        }
        if let detail = result?.outcome.detail, !detail.isEmpty {
            parts.append(detail)
        }
        if task.kind != .guidedDiagnostic, selectable {
            parts.append(selected ? "Selected" : "Not selected")
        }
        return parts.joined(separator: ", ")
    }

    private var tintColor: Color {
        ContentView.SidebarItem.optimize.tint
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
