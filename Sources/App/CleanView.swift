import SwiftUI
import Core
import Features
import UI

struct CleanView: View {
    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var model = CleanModel.shared
    @State private var trashNotice: String?
    @State private var preparingReview = false
    @State private var reviewTask: Task<Void, Never>?
    @State private var review: ReviewRequest?

    @ObservedObject private var activity = WorkCoordinator.shared

    private let tint = ContentView.SidebarItem.clean.tint

    private var plans: [CleanScanner.Section: SafeFileDeleter.Plan] {
        coordinator.cleanPlans ?? [:]
    }

    private var totalReclaimable: Int64 {
        plans.values.reduce(0) { $0 + $1.totalReclaimable }
    }

    private var subtitle: String {
        if model.isScanning {
            return "Measuring…"
        }
        guard coordinator.cleanPlans != nil else { return "Caches, logs, temporary files and the Trash" }
        return totalReclaimable > 0
            ? "\(ByteSizeFormatter.format(totalReclaimable)) of cleanup candidates to review"
            :
            (coordinator.coverage[.clean]?
                .isPartial == true ? "No candidates in checked locations · partial scan" : "Nothing to clean right now")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Clean up", subtitle: subtitle, systemImage: ContentView.SidebarItem.clean.icon, tint: tint) {
                if totalReclaimable > 0, !model.isScanning {
                    Button("Review All (\(ByteSizeFormatter.format(totalReclaimable)))") { reviewAll() }
                        .carePrimaryAction()
                        .tint(tint)
                        .disabled(activity.isBusy)
                }
                scanButton
            }

            if preparingReview {
                ScanProgressBar(
                    "Preparing your review",
                    detail: "Reading the exact items. Nothing is being deleted.",
                    onCancel: { reviewTask?.cancel() }
                )
                .padding(.horizontal).padding(.bottom, 12)
            }
            if model.isScanning {
                ScanProgressBar(
                    "Measuring cleanable data",
                    detail: "\(model.sectionsDone) of \(model.sectionCount) categories",
                    fraction: Double(model.sectionsDone) / Double(model.sectionCount),
                    onCancel: model.cancel
                )
                .padding([.horizontal, .bottom])
            }

            if coordinator.cleanPlans != nil, totalReclaimable > 0 {
                CareSummary([("To review", ByteSizeFormatter.format(totalReclaimable)),
                             ("Items", plans.values.reduce(0) { $0 + $1.items.count }.formatted()),
                             ("Categories", plans.values.filter { !$0.items.isEmpty }.count.formatted())])
            }
            if let coverage = coordinator.coverage[.clean] {
                ScanCoverageView(coverage).padding(.horizontal).padding(.bottom, 8)
            }
            if coordinator.cleanPlans == nil {
                if !model.isScanning {
                    CareEmptyState("Make a little room.", systemImage: "internaldrive", description: Text(
                        "Find caches, logs, temporary files and Trash contents that are safe to remove. Nothing is removed until you review it."
                    )) {
                        Button("Scan") { model.scan() }.carePrimaryAction().disabled(activity.isBusy)
                    }
                } else {
                    Spacer()
                }
            } else if totalReclaimable == 0 {
                CareEmptyState(
                    coordinator.coverage[.clean]?.isPartial == true ? "No Cleanup Candidates in Checked Locations" : "Nothing to Clean",
                    systemImage: "checkmark.circle",
                    description: Text("No removable caches, logs or Trash contents were found.")
                )
            } else {
                let maxReclaimable = plans.values.map(\.totalReclaimable).max() ?? 1
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(CleanScanner.Section.allCases) { section in
                            if let plan = plans[section], !plan.items.isEmpty {
                                CleanSectionCard(
                                    section: section,
                                    plan: plan,
                                    tint: tint,
                                    maxReclaimable: maxReclaimable
                                ) {
                                    openReview(plan, title: section.displayName, subtitle: section.explanation)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 22)
                }
            }
        }
        .careScreen()
        .onDisappear { reviewTask?.cancel() }
        .onReceive(AppNavigation.shared.$pendingTrashReview) { requested in
            guard requested else { return }
            AppNavigation.shared.pendingTrashReview = false
            prepareTrashReview()
        }
        .alert("Trash review", isPresented: Binding(get: { trashNotice != nil }, set: {
            if !$0 {
                trashNotice = nil
            }
        })) {
            Button("OK", role: .cancel) { trashNotice = nil }
        } message: { Text(trashNotice ?? "") }
        .sheet(item: $review) { request in
            PlanReviewView(
                plan: request.plan,
                title: request.title,
                subtitle: request.subtitle,
                action: request.action,
                revalidate: { plan in
                    let worker = Task.detached(priority: .userInitiated) { CleanScanner.revalidated(plan) }
                    return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                }
            ) { result in
                if let result, !result.dryRun {
                    coordinator.removeCleanItems(ids: result.removedIDs)
                    if !result.removedIDs.isEmpty {
                        AnalyzeScanSession.shared.markStale()
                    }
                }
                review = nil
            }
        }
    }

    @ViewBuilder
    private var scanButton: some View {
        let button = Button(coordinator.cleanPlans == nil ? "Scan" : "Rescan") { model.scan() }
            .keyboardShortcut("r", modifiers: .command)
            .tint(tint)
            .disabled(activity.isBusy)
        if totalReclaimable > 0 {
            button.buttonStyle(.bordered)
        } else {
            button.carePrimaryAction()
        }
    }

    private func prepareTrashReview() {
        guard !preparingReview, review == nil,
              let lease = activity.begin("Preparing Trash review", cancel: { reviewTask?.cancel() })
        else {
            trashNotice = "Finish or cancel the current task before reviewing the Trash."
            return
        }
        preparingReview = true
        reviewTask = Task {
            defer { preparingReview = false; reviewTask = nil; activity.finish(lease) }
            let read = Task.detached(priority: .userInitiated) { TrashReview.prepare() }
            let prepared = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
            guard !Task.isCancelled else { return }
            if prepared.plan.items.isEmpty {
                trashNotice = prepared.coverage.isPartial
                    ? "The Trash could not be fully checked. Review its permissions in System Settings or open it in Finder."
                    : "No removable items were found in the Trash."
            } else {
                review = ReviewRequest(
                    plan: prepared.plan,
                    title: "Review Trash",
                    subtitle: "Choose the exact items to delete permanently. This cannot be undone."
                        + (prepared.coverage.isPartial ? " Some locations could not be checked; only the listed items are included." : ""),
                    action: "menubar.emptyTrash"
                )
            }
        }
    }

    /// Merges every section's plan into one, so all of Clean can be reviewed
    /// and confirmed in a single sheet instead of one card at a time.
    private func reviewAll() {
        let merged = SafeFileDeleter.Plan.merged(CleanScanner.Section.allCases.compactMap { plans[$0] })
        openReview(merged, title: "Clean", subtitle: nil)
    }

    /// The scan may be hours old (a background scan, or one left on screen).
    /// Before asking for confirmation, drop anything that has stopped being a
    /// target since — the cache of an app that's now open, a temp file that's
    /// been touched.
    private func openReview(_ plan: SafeFileDeleter.Plan, title: String, subtitle: String?) {
        guard !preparingReview, review == nil,
              let lease = activity.begin("Preparing cleanup review", cancel: { reviewTask?.cancel() }) else { return }
        preparingReview = true
        reviewTask = Task {
            defer { preparingReview = false; reviewTask = nil; activity.finish(lease) }
            let worker = Task.detached(priority: .userInitiated) { CleanScanner.revalidated(plan) }
            let current = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            let dropped = plan.items.count - current.items.count
            if dropped > 0 {
                coordinator.removeCleanItems(ids: Set(plan.items.map(\.id)).subtracting(current.items.map(\.id)))
            }
            guard !current.items.isEmpty else {
                trashNotice = "These items are now in use or no longer eligible. Rescan after closing build tools and apps."
                return
            }
            var note = subtitle
            if dropped > 0 {
                let left = "\(dropped) item(s) are now in use or no longer eligible and were left out."
                note = [subtitle, left].compactMap { $0 }.joined(separator: " ")
            }
            review = ReviewRequest(plan: current, title: title, subtitle: note, action: "clean")
        }
    }
}

/// Card-style row: icon badge, name, what the category is, a size bar scaled
/// relative to the biggest category in this scan (so you can tell at a glance
/// which categories are actually worth reviewing), and the reclaimable size.
private struct CleanSectionCard: View {
    let section: CleanScanner.Section
    let plan: SafeFileDeleter.Plan
    let tint: Color
    let maxReclaimable: Int64
    let onReview: () -> Void

    /// What Developer Tools does and doesn't cover, on hover rather than as
    /// a permanent block on the Clean screen.
    private static let devToolsCoverage = """
    Covers selected Mac caches for Xcode, SwiftPM, npm, Node, Go, Cargo, pip, Gradle and Homebrew, \
    skipped while those tools run. Docker images, containers and volumes are managed in Docker Desktop \
    and aren't included; volumes can hold databases you need. Project folders such as node_modules \
    are covered separately by Project Purge (Settings → Advanced).
    """

    private var relativeSize: Double {
        maxReclaimable > 0 ? Double(plan.totalReclaimable) / Double(maxReclaimable) * 100 : 0
    }

    private var countText: String {
        var text = "\(plan.items.count) item\(plan.items.count == 1 ? "" : "s")"
        if !plan.protectedItems.isEmpty {
            text += " · \(plan.protectedItems.count) protected"
        }
        return text
    }

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .foregroundStyle(tint)
                    .font(.system(size: 15, weight: .semibold))
                    .iconBadge(tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(section.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(ByteSizeFormatter.format(plan.totalReclaimable))
                            .font(.subheadline.bold())
                            .monospacedDigit()
                            .foregroundStyle(tint)
                    }
                    SizeBar(percent: relativeSize, color: tint)
                    Text(section.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(CareTheme.secondaryInk)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .help(section == .devTools ? Self.devToolsCoverage : "")
        .accessibilityLabel("\(section.displayName), \(ByteSizeFormatter.format(plan.totalReclaimable)), \(countText)")
        .accessibilityHint("Opens the list of items to review")
    }
}
