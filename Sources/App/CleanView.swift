import SwiftUI
import Core
import Features
import UI

struct CleanView: View {
    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var model = CleanModel.shared
    @State private var review: ReviewRequest?

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
            ? "\(ByteSizeFormatter.format(totalReclaimable)) can be reclaimed"
            : "Nothing to clean right now"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("System Cleanup", subtitle: subtitle, systemImage: ContentView.SidebarItem.clean.icon, tint: tint) {
                if totalReclaimable > 0, !model.isScanning {
                    Button("Review All (\(ByteSizeFormatter.format(totalReclaimable)))") { reviewAll() }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                }
                scanButton
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

            if coordinator.cleanPlans == nil {
                if !model.isScanning {
                    ContentUnavailableView {
                        Label("No Scan Yet", systemImage: "internaldrive")
                    } description: {
                        Text("Find caches, logs, temporary files and Trash contents that are safe to remove. Nothing is removed until you review it.")
                    } actions: {
                        Button("Scan") { model.scan() }
                            .buttonStyle(.borderedProminent)
                            .tint(tint)
                    }
                } else {
                    Spacer()
                }
            } else if totalReclaimable == 0 {
                ContentUnavailableView(
                    "Nothing to Clean",
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
                    .padding()
                }
            }
        }
        .sheet(item: $review) { request in
            PlanReviewView(
                plan: request.plan,
                title: request.title,
                subtitle: request.subtitle,
                action: request.action
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
            .disabled(model.isScanning)
        if totalReclaimable > 0 {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderedProminent)
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
        let current = CleanScanner.revalidated(plan)
        let dropped = plan.items.count - current.items.count
        if dropped > 0 {
            coordinator.removeCleanItems(ids: Set(plan.items.map(\.id)).subtracting(current.items.map(\.id)))
        }
        guard !current.items.isEmpty else { return }
        var note = subtitle
        if dropped > 0 {
            let left = "\(dropped) item\(dropped == 1 ? " is" : "s are") now in use and \(dropped == 1 ? "was" : "were") left out."
            note = [subtitle, left].compactMap { $0 }.joined(separator: " ")
        }
        review = ReviewRequest(plan: current, title: title, subtitle: note, action: "clean")
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
                        .foregroundStyle(.tertiary)
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
        .accessibilityLabel("\(section.displayName), \(ByteSizeFormatter.format(plan.totalReclaimable)), \(countText)")
        .accessibilityHint("Opens the list of items to review")
    }
}
