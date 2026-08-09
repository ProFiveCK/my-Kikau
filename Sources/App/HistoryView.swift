import SwiftUI
import Core

struct HistoryView: View {
    @State private var entries: [OperationLog.Entry] = []
    @State private var totalFreed: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Operation History").font(.title2).bold()
                Spacer()
                Text("Total freed: \(ByteSizeFormatter.format(totalFreed))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            if entries.isEmpty {
                ContentUnavailableView(
                    "No Operations Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Operations will appear here after you run cleanup, uninstall, or purge.")
                )
            } else {
                List(entries) { entry in
                    HistoryRow(entry: entry)
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        entries = OperationLog.shared.recent(limit: 200)
        totalFreed = OperationLog.shared.totalFreed()
    }
}

private struct HistoryRow: View {
    let entry: OperationLog.Entry

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(entry.action.capitalized)
                    .font(.body)
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(ByteSizeFormatter.format(entry.sizeBytes))
                    .font(.caption)
                    .monospacedDigit()
                Text(entry.outcome.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch entry.mode {
        case .trash: "trash"
        case .permanent: "trash.slash"
        }
    }

    private var color: Color {
        switch entry.outcome {
        case .success: .green
        case .failed: .red
        case .skipped: .orange
        case .dryRun: .blue
        }
    }
}