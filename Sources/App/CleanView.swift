import SwiftUI
import Core
import Features
import UI

struct CleanView: View {
    @State private var plans: [CleanScanner.Section: SafeFileDeleter.Plan] = [:]
    @State private var scanning = false
    @State private var selectedPlan: SafeFileDeleter.Plan?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
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
                List(CleanScanner.Section.allCases) { section in
                    if let plan = plans[section], !plan.isEmpty {
                        Section(section.displayName) {
                            CleanSectionRow(section: section, plan: plan) {
                                selectedPlan = plan
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedPlan) { plan in
            PlanReviewView(plan: plan, title: "Clean") { dryRun in
                if !dryRun || dryRun {
                    // Execute and dismiss
                    let result = SafeFileDeleter.shared.execute(plan, mode: .trash, dryRun: dryRun, action: "clean")
                    print("Clean \(dryRun ? "preview" : "done"): freed \(ByteSizeFormatter.format(result.freedBytes))")
                }
                selectedPlan = nil
            }
        }
    }
}

private struct CleanSectionRow: View {
    let section: CleanScanner.Section
    let plan: SafeFileDeleter.Plan
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack {
                Image(systemName: section.icon)
                    .frame(width: 24)
                VStack(alignment: .leading) {
                    Text("\(plan.items.count) items")
                    Text(ByteSizeFormatter.format(plan.totalReclaimable))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}