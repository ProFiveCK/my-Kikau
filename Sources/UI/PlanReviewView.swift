import SwiftUI
import Core

/// Shared view for previewing a deletion plan before execution.
/// Used by Clean, Uninstall, and Purge features.
/// Mirrors Mole's dry-run + confirm flow.
public struct PlanReviewView: View {
    public let plan: SafeFileDeleter.Plan
    public let title: String
    public let onExecute: (Bool) -> Void  // true = dryRun

    @State private var isDryRun = false

    public init(plan: SafeFileDeleter.Plan, title: String, onExecute: @escaping (Bool) -> Void) {
        self.plan = plan
        self.title = title
        self.onExecute = onExecute
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text("\(plan.items.count) items · \(ByteSizeFormatter.format(plan.totalReclaimable))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Dry Run", isOn: $isDryRun)
                    .toggleStyle(.switch)
            }
            .padding()

            Divider()

            // Items list
            List {
                Section("Will Remove (\(ByteSizeFormatter.format(plan.totalReclaimable)))") {
                    ForEach(plan.items) { item in
                        PlanItemRow(item: item)
                    }
                }
                if !plan.protectedItems.isEmpty {
                    Section("Protected (Skipped)") {
                        ForEach(plan.protectedItems) { item in
                            PlanItemRow(item: item)
                                .foregroundStyle(.red)
                        }
                    }
                }
                if !plan.missingItems.isEmpty {
                    Section("Not Found") {
                        ForEach(plan.missingItems) { item in
                            PlanItemRow(item: item)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            // Action bar
            HStack {
                if !plan.protectedItems.isEmpty {
                    Label("\(plan.protectedItems.count) protected", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { onExecute(false) }
                    .keyboardShortcut(.cancelAction)
                Button(isDryRun ? "Preview" : "Confirm Delete") {
                    onExecute(isDryRun)
                }
                .buttonStyle(.borderedProminent)
                .tint(isDryRun ? .blue : .red)
                .disabled(plan.items.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

private struct PlanItemRow: View {
    let item: SafeFileDeleter.Item

    var body: some View {
        HStack {
            Image(systemName: item.protected ? "exclamationmark.shield" : categoryIcon)
                .foregroundStyle(item.protected ? .red : .secondary)
            VStack(alignment: .leading) {
                Text(item.url.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(ByteSizeFormatter.format(item.sizeBytes))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var categoryIcon: String {
        switch item.category {
        case .cache: "internaldrive"
        case .log: "doc.text"
        case .trash: "trash"
        case .leftover: "app.dashed"
        case .artifact: "hammer"
        case .app: "app"
        case .installer: "archivebox"
        }
    }
}