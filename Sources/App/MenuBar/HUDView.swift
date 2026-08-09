import AppKit
import SwiftUI
import Core
import Features
import UI

/// Menu bar HUD showing live system metrics plus a couple of one-tap actions.
struct HUDView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var metricsService = MetricsService.shared
    @State private var trashStatus: String?
    @State private var freeingMemory = false
    @State private var memoryStatus: String?
    private let canPurgeMemory = MemoryOptimizer.isPurgeAvailable()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snap = metricsService.snapshot {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(healthColor(snap.healthScore).opacity(0.18))
                        Text("\(snap.healthScore)")
                            .font(.system(size: 16, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(healthColor(snap.healthScore))
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("myKikau")
                            .font(.headline)
                        Text(snap.healthScoreMsg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()

                VStack(spacing: 8) {
                    MetricRow(label: "CPU", value: "\(Int(snap.cpu.usage))%", percent: snap.cpu.usage, color: .blue)
                    MetricRow(
                        label: "Memory",
                        value: "\(ByteSizeFormatter.format(Int64(snap.memory.available))) free",
                        percent: snap.memory.usedPercent,
                        color: SizeBar.color(for: snap.memory.usedPercent)
                    )
                    if let disk = snap.disks.first {
                        MetricRow(
                            label: "Disk",
                            value: "\(ByteSizeFormatter.format(Int64(disk.total - disk.used))) free",
                            percent: disk.usedPercent,
                            color: SizeBar.color(for: disk.usedPercent)
                        )
                    }
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
                HStack {
                    Label(HealthScore.formatUptime(snap.uptimeSeconds), systemImage: "clock")
                    Spacer()
                    Text(snap.host)
                        .lineLimit(1)
                }
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
            Button {
                AppNavigation.shared.pendingSelection = .status
                openMainWindow()
            } label: {
                Label("Open Dashboard", systemImage: "gauge.with.dots.needle.50percent")
            }
            Button {
                AppNavigation.shared.pendingSelection = .clean
                openMainWindow()
            } label: {
                Label("Open Clean", systemImage: "internaldrive")
            }
            Button {
                freeInactiveMemory()
            } label: {
                Label(memoryActionTitle, systemImage: "memorychip")
            }
            .disabled(freeingMemory)
            if let memoryStatus {
                Text(memoryStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                emptyTrash()
            } label: {
                Label("Empty Trash…", systemImage: "trash")
            }
            if let trashStatus {
                Text(trashStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit myKikau", systemImage: "power")
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 280)
        .onAppear { metricsService.subscribe() }
        .onDisappear { metricsService.unsubscribe() }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.unhide(nil)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows
                .filter { $0.canBecomeMain || $0.canBecomeKey }
                .forEach { $0.makeKeyAndOrderFront(nil) }
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
        if result.failed == 0 {
            ScanEverythingCoordinator.shared.clearCleanPlan(for: .trash)
        }
    }

    private func freeInactiveMemory() {
        guard !freeingMemory else { return }
        guard canPurgeMemory else {
            AppNavigation.shared.pendingSelection = .status
            AppNavigation.shared.pendingProcessMode = .memory
            openMainWindow()
            memoryStatus = "Showing apps using the most memory."
            return
        }
        freeingMemory = true
        memoryStatus = nil
        Task {
            let result = await MemoryOptimizer.freeInactiveMemory()
            await MainActor.run {
                freeingMemory = false
                memoryStatus = result.message
            }
        }
    }

    private var memoryActionTitle: String {
        if freeingMemory { return "Freeing Memory..." }
        return canPurgeMemory ? "Free Inactive Memory" : "View Memory Users"
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
    let value: String
    let percent: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
            }
            SizeBar(percent: percent, color: color)
        }
    }
}
