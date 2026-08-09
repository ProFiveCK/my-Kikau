import AppKit
import SwiftUI
import Core
import Features
import UI

/// Menu bar HUD showing live system metrics plus a couple of one-tap actions.
struct HUDView: View {
    @ObservedObject private var metricsService = MetricsService.shared
    @State private var trashStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snap = metricsService.snapshot {
                // Health score
                HStack {
                    Circle()
                        .fill(healthColor(snap.healthScore))
                        .frame(width: 12, height: 12)
                    Text("Health \(snap.healthScore)")
                        .font(.headline)
                    Spacer()
                    Text(snap.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // CPU
                MetricRow(label: "CPU", percent: snap.cpu.usage, color: .blue)
                MetricRow(label: "Memory", percent: snap.memory.usedPercent, color: SizeBar.color(for: snap.memory.usedPercent))

                if let disk = snap.disks.first {
                    MetricRow(label: "Disk", percent: disk.usedPercent, color: SizeBar.color(for: disk.usedPercent))
                }

                if let battery = snap.batteries.first {
                    HStack {
                        Text("Battery")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(battery.percent))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }

                Divider()
                Text("Uptime \(HealthScore.formatUptime(snap.uptimeSeconds))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Collecting metrics...")
                    .frame(maxWidth: .infinity, minHeight: 100)
            }

            Divider()

            // Quick actions — kept to genuinely safe/useful ones. No fake
            // "boost performance" placebo buttons; Empty Trash confirms first
            // and reuses the same SafeFileDeleter funnel every other delete
            // in the app goes through.
            Button("Empty Trash…") { emptyTrash() }
            if let trashStatus {
                Text(trashStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Open Clean…") {
                AppNavigation.shared.pendingSelection = .clean
                openMainWindow()
            }

            Divider()

            Button("Open myKikau") { openMainWindow() }
            Button("Quit myKikau") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 240)
        .onAppear { metricsService.subscribe() }
        .onDisappear { metricsService.unsubscribe() }
    }

    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "myKikau" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func emptyTrash() {
        let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: trashURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ), !items.isEmpty else {
            trashStatus = "Trash is already empty"
            return
        }

        let plan = SafeFileDeleter.shared.preview(items, category: .trash)
        guard !plan.items.isEmpty else {
            trashStatus = "Nothing removable in Trash"
            return
        }

        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "\(plan.items.count) item(s), \(ByteSizeFormatter.format(plan.totalReclaimable)). This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = SafeFileDeleter.shared.execute(plan, mode: .permanent, dryRun: false, action: "menubar.emptyTrash")
        trashStatus = "Freed \(ByteSizeFormatter.format(result.freedBytes))"
    }

    private func healthColor(_ score: Int) -> Color {
        switch score {
        case 85...: .green
        case 65..<85: .yellow
        case 45..<65: .orange
        default: .red
        }
    }
}

private struct MetricRow: View {
    let label: String
    let percent: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(ByteSizeFormatter.formatPercent(percent))
                    .font(.caption)
                    .monospacedDigit()
            }
            SizeBar(percent: percent, color: color)
        }
    }
}
