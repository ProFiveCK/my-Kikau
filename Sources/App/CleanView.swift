import SwiftUI
import Core
import Features
import UI

struct CleanView: View {
    @State private var plans: [CleanScanner.Section: SafeFileDeleter.Plan] = [:]
    @State private var scanning = false
    @State private var selectedPlan: SafeFileDeleter.Plan?

    private let tint = ContentView.SidebarItem.clean.tint

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: ContentView.SidebarItem.clean.icon)
                    .foregroundStyle(tint)
                Text("System Cleanup").font(.title2).bold()
                Spacer()
                Button(scanning ? "Scanning..." : "Scan") {
                    scanning = true
                    Task.detached {
                        let result = CleanScanner.scanAll()
                        await MainActor.run {
                            plans = result
                            scanning = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(scanning)
            }
            .padding()

            if plans.isEmpty && !scanning {
                ContentUnavailableView(
                    "No Scan Yet",
                    systemImage: "internaldrive",
                    description: Text("Click Scan to find caches, logs, and trash to reclaim disk space.")
                )
            } else {
                let maxReclaimable = plans.values.map(\.totalReclaimable).max() ?? 1
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(CleanScanner.Section.allCases) { section in
                            if let plan = plans[section], !plan.isEmpty {
                                CleanSectionCard(
                                    section: section,
                                    plan: plan,
                                    tint: tint,
                                    maxReclaimable: maxReclaimable
                                ) {
                                    selectedPlan = plan
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $selectedPlan) { plan in
            PlanReviewView(plan: plan, title: "Clean", onCancel: { selectedPlan = nil }) { dryRun in
                let result = SafeFileDeleter.shared.execute(plan, mode: .trash, dryRun: dryRun, action: "clean")
                if !dryRun, result.failed == 0 {
                    for (section, existingPlan) in plans where existingPlan.id == plan.id {
                        plans[section] = SafeFileDeleter.Plan(items: [], protectedItems: [], missingItems: [])
                        ScanEverythingCoordinator.shared.clearCleanPlan(for: section)
                    }
                }
                selectedPlan = nil
            }
        }
        .onAppear {
            // Adopt a scan already run from the Status dashboard's "Scan
            // Everything" instead of forcing a redundant rescan.
            if plans.isEmpty, let cached = ScanEverythingCoordinator.shared.cleanPlans {
                plans = cached
            }
        }
    }
}

/// Card-style row: icon badge, name, item count, a size bar scaled relative to
/// the biggest category in this scan (so you can tell at a glance which
/// categories are actually worth reviewing), and the reclaimable size.
private struct CleanSectionCard: View {
    let section: CleanScanner.Section
    let plan: SafeFileDeleter.Plan
    let tint: Color
    let maxReclaimable: Int64
    let onReview: () -> Void

    private var relativeSize: Double {
        maxReclaimable > 0 ? Double(plan.totalReclaimable) / Double(maxReclaimable) * 100 : 0
    }

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: section.icon)
                        .foregroundStyle(tint)
                        .font(.system(size: 15, weight: .semibold))
                }
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
                    Text("\(plan.items.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
