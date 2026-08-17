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
        VStack(alignment: .leading, spacing: 12) {
            if let snap = metricsService.snapshot {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("myKikau")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Mac Health: \(statusWord(for: snap.healthScore))")
                            .font(.caption)
                            .foregroundStyle(healthColor(snap.healthScore))
                        Text(statusDetail(for: snap))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: healthSymbol(for: snap.healthScore))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(healthColor(snap.healthScore))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(healthColor(snap.healthScore).opacity(0.13))
                        )
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

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
                    if let gpu = snap.gpu.first, gpu.usage >= 0 {
                        MetricRow(label: "GPU", value: "\(Int(gpu.usage))%", percent: gpu.usage, color: .purple)
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

            QuickActionsGrid(
                memoryActionTitle: memoryActionTitle,
                freeingMemory: freeingMemory,
                memoryStatus: memoryStatus,
                trashStatus: trashStatus,
                openDashboard: {
                    AppNavigation.shared.pendingSelection = .status
                    openMainWindow()
                },
                openClean: {
                    AppNavigation.shared.pendingSelection = .clean
                    openMainWindow()
                },
                freeMemory: freeInactiveMemory,
                emptyTrash: emptyTrash
            )

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit myKikau", systemImage: "power")
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 306)
        .onAppear { metricsService.subscribe() }
        .onDisappear { metricsService.unsubscribe() }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.unhide(nil)
        NSApplication.shared.windows
            .filter { $0.canBecomeMain || $0.canBecomeKey }
            .forEach { $0.makeKeyAndOrderFront(nil) }
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

    private func statusWord(for score: Int) -> String {
        switch score {
        case 90...: "Great"
        case 75..<90: "Good"
        case 60..<75: "OK"
        default: "Needs Maintenance"
        }
    }

    private func statusDetail(for snapshot: MetricsSnapshot) -> String {
        let parts = snapshot.healthScoreMsg.components(separatedBy: ": ")
        guard parts.count > 1 else { return "No urgent issues detected" }
        return parts.dropFirst().joined(separator: ": ")
    }

    private func healthSymbol(for score: Int) -> String {
        switch score {
        case 85...: "checkmark.circle.fill"
        case 65..<85: "exclamationmark.circle.fill"
        case 45..<65: "exclamationmark.triangle.fill"
        default: "xmark.octagon.fill"
        }
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

private struct QuickActionsGrid: View {
    let memoryActionTitle: String
    let freeingMemory: Bool
    let memoryStatus: String?
    let trashStatus: String?
    let openDashboard: () -> Void
    let openClean: () -> Void
    let freeMemory: () -> Void
    let emptyTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                HUDActionCard(
                    title: "Dashboard",
                    subtitle: "Open status",
                    systemImage: "gauge.with.dots.needle.50percent",
                    tint: .accentColor,
                    action: openDashboard
                )
                HUDActionCard(
                    title: "Clean",
                    subtitle: "Review junk",
                    systemImage: "internaldrive",
                    tint: .blue,
                    action: openClean
                )
                HUDActionCard(
                    title: memoryActionTitle,
                    subtitle: memoryStatus ?? "Memory tools",
                    systemImage: "memorychip",
                    tint: .teal,
                    disabled: freeingMemory,
                    action: freeMemory
                )
                HUDActionCard(
                    title: "Empty Trash",
                    subtitle: trashStatus ?? "Confirm first",
                    systemImage: "trash",
                    tint: .red,
                    action: emptyTrash
                )
            }
        }
    }
}

private struct HUDActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24, height: 24)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
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
