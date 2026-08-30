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
    @State private var netInfo: NetworkInfo?
    @State private var copiedIP = false
    private let canPurgeMemory = MemoryOptimizer.isPurgeAvailable()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snap = metricsService.snapshot {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("myKikau")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Mac Health: \(healthBand(snap).word)")
                            .font(.caption)
                            // The branded light teal works on the dashboard's
                            // dark hero card but washes out on this system
                            // popover in Light Mode. Keep teal on the icon and
                            // use macOS's adaptive high-contrast text color here.
                            .foregroundStyle(.primary)
                        Text(statusDetail(for: snap))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: healthBand(snap).symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(healthBand(snap).color)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(healthBand(snap).color.opacity(0.13))
                        )
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

                // CPU/Memory/Disk are each a shortcut into exactly the view
                // that answers "why" — Top CPU/Memory Processes or the Disk
                // Analyser — instead of just being numbers you can only look
                // at. GPU has no equivalent drill-down anywhere in the app,
                // so it deliberately stays a plain, non-tappable row rather
                // than faking an affordance that goes nowhere.
                VStack(spacing: 8) {
                    MetricRow(label: "CPU", value: "\(Int(snap.cpu.usage))%", percent: snap.cpu.usage, color: .blue) {
                        openProcessList(mode: .cpu)
                    }
                    MetricRow(
                        label: "Memory",
                        value: "\(ByteSizeFormatter.format(Int64(snap.memory.available))) free",
                        percent: snap.memory.usedPercent,
                        color: SizeBar.color(for: snap.memory.usedPercent)
                    ) {
                        openProcessList(mode: .memory)
                    }
                    if let disk = snap.disks.first {
                        MetricRow(
                            label: "Disk",
                            value: "\(ByteSizeFormatter.format(Int64(disk.total - disk.used))) free",
                            percent: disk.usedPercent,
                            color: SizeBar.color(for: disk.usedPercent)
                        ) {
                            AppNavigation.shared.pendingSelection = .analyze
                            openMainWindow()
                        }
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

                if let net = netInfo {
                    networkRow(net)
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
                canPurgeMemory: canPurgeMemory,
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
                openOptimise: {
                    AppNavigation.shared.pendingSelection = .optimize
                    openMainWindow()
                },
                freeMemory: freeInactiveMemory,
                emptyTrash: emptyTrash
            )

            Divider()

            // No keyboard shortcut here deliberately: `.cancelAction` binds to
            // Escape, and Escape is exactly the key someone reaches for to
            // dismiss this popover — binding it to Quit instead would mean a
            // reflex dismiss-tap quits the whole app. Cmd+Q still works
            // app-wide via the standard app menu; clicking this button always
            // works regardless.
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit myKikau", systemImage: "power")
            }
        }
        .padding()
        .frame(width: 306)
        .onAppear {
            metricsService.subscribe()
            netInfo = NetworkInfo.collect()
            copiedIP = false
        }
        .onDisappear { metricsService.unsubscribe() }
    }

    /// Connection + local IP, tappable to open the full Network screen, with a
    /// one-tap copy for the IP address itself (a frequent "what's my IP" reach).
    @ViewBuilder
    private func networkRow(_ net: NetworkInfo) -> some View {
        HStack(spacing: 8) {
            Button {
                AppNavigation.shared.pendingSelection = .network
                openMainWindow()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: networkSymbol(net))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(net.shortLabel)
                            .font(.caption)
                            .lineLimit(1)
                        Text(net.localIPv4 ?? "No IP address")
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let ip = net.localIPv4 {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                    copiedIP = true
                } label: {
                    Image(systemName: copiedIP ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copiedIP ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy IP address")
            }
        }
    }

    private func networkSymbol(_ net: NetworkInfo) -> String {
        switch net.connectionName {
        case "Wi-Fi": return "wifi"
        case "Ethernet": return "cable.connector"
        default: return "network.slash"
        }
    }

    /// `openWindow(id:)` already brings the singleton "main" `Window` scene
    /// forward and makes it key — that's its whole job. This used to also
    /// walk every `NSApplication.shared.windows` entry and force each one
    /// `canBecomeMain || canBecomeKey` to the front, which was a blunt
    /// workaround from before "main" was a singleton scene. The bug it left
    /// behind: AppKit keeps a SwiftUI `Settings` scene's `NSWindow` alive in
    /// `NSApp.windows` for the app's whole lifetime once it's been opened
    /// even once (so ⌘, can reopen it instantly) — closed or not, it's still
    /// in that array and `canBecomeKey`, so the old loop surfaced it right
    /// alongside the dashboard on every single "Dashboard" click after that
    /// point. `activate(ignoringOtherApps:)` is still needed here (this app
    /// runs `.accessory` by default with no Dock icon, so without it the
    /// window can open behind whatever app currently has focus).
    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.unhide(nil)
    }

    private func openProcessList(mode: ProcessMonitor.SortMode) {
        AppNavigation.shared.pendingSelection = .status
        AppNavigation.shared.pendingProcessMode = mode
        openMainWindow()
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
        // The card that calls this is only rendered when `canPurgeMemory` is
        // true (otherwise the grid shows an "Optimise" shortcut instead), so
        // there's no "View Memory Users" fallback here anymore — that just
        // duplicated the tappable Memory metric row above.
        guard !freeingMemory, canPurgeMemory else { return }
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
        freeingMemory ? "Freeing Memory..." : "Free Inactive Memory"
    }

    /// The one canonical band definition in `HealthScore` — also used by the
    /// dashboard's hero card, so the menu bar and the main window can't
    /// disagree on what a given score means. This used to be three separate
    /// hand-rolled `switch`es here (word bands at 90/75/60, color/symbol
    /// bands at 85/65/45) that didn't line up with each other, so a score in
    /// the high 70s/low 80s could show "Good" rendered in cautionary yellow.
    private func healthBand(_ snapshot: MetricsSnapshot) -> HealthScore.Band {
        HealthScore.band(for: snapshot.healthScore)
    }

    /// Everything after the first ":" in e.g. "Fair: High CPU, Heavy Disk IO",
    /// falling back to the band's own explanation when there's no itemized
    /// issue (matches `StatusView`'s `issuesDetail` fallback behavior).
    private func statusDetail(for snapshot: MetricsSnapshot) -> String {
        let parts = snapshot.healthScoreMsg.components(separatedBy: ": ")
        guard parts.count > 1 else { return healthBand(snapshot).explanation }
        return parts.dropFirst().joined(separator: ": ")
    }
}

private struct QuickActionsGrid: View {
    let canPurgeMemory: Bool
    let memoryActionTitle: String
    let freeingMemory: Bool
    let memoryStatus: String?
    let trashStatus: String?
    let openDashboard: () -> Void
    let openClean: () -> Void
    let openOptimise: () -> Void
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
                // "See what's using memory" is already the tappable Memory
                // metric row above, so this slot is only a memory control when
                // it can do something that row can't — actually purge inactive
                // file cache. Where `purge` isn't available, show the Optimise
                // shortcut instead rather than a second link to the same
                // process list.
                if canPurgeMemory {
                    HUDActionCard(
                        title: memoryActionTitle,
                        subtitle: memoryStatus ?? "Purge inactive file cache",
                        systemImage: "memorychip",
                        tint: .teal,
                        disabled: freeingMemory,
                        action: freeMemory
                    )
                } else {
                    HUDActionCard(
                        title: "Optimise",
                        subtitle: "Run maintenance",
                        systemImage: "wrench.and.screwdriver",
                        tint: .orange,
                        action: openOptimise
                    )
                }
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
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowContent(showsChevron: true) }
                    .buttonStyle(.plain)
            } else {
                rowContent(showsChevron: false)
            }
        }
        .contentShape(Rectangle())
    }

    private func rowContent(showsChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            SizeBar(percent: percent, color: color)
        }
    }
}
