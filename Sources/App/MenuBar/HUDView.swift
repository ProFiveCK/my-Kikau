import AppKit
import SwiftUI
import Core
import Features
import UI

/// A compact companion to Care hub. File removal always opens the main
/// window's exact-item review; the popover itself never deletes files.
struct HUDView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var metrics = MetricsService.shared
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @ObservedObject private var work = WorkCoordinator.shared
    @State private var netInfo: NetworkInfo?
    @State private var copiedIP = false
    /// Network is a sidebar screen only while advanced tools are on.
    @AppStorage(AppStorageKey.developerToolsEnabled) private var advancedTools = false
    @State private var memoryStatus: String?
    @State private var freeingMemory = false
    private let canPurgeMemory = MemoryOptimizer.isPurgeAvailable()

    private var popoverHeight: CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        return min(660, max(380, (screen?.visibleFrame.height ?? 760) - 28))
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { navigate(.status) } label: {
                HStack(spacing: 11) {
                    AppBrandIcon(size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("myKikau").font(.system(.title2, design: .rounded).weight(.bold)).tracking(-0.6)
                        Text("Your Mac, at a glance").font(.caption).foregroundStyle(CareTheme.secondaryInk)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(CareTheme.accent)
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open Care hub")

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let snapshot = metrics.snapshot {
                        status(snapshot)
                        VStack(spacing: 10) {
                            HUDMetric(
                                label: "CPU",
                                value: "\(Int(snapshot.cpu.usage))% in use",
                                percent: snapshot.cpu.usage,
                                tint: CareTheme.blue
                            ) {
                                openProcesses(.cpu)
                            }
                            HUDMetric(
                                label: "Memory",
                                value: "\(ByteSizeFormatter.format(Int64(snapshot.memory.available))) available",
                                percent: snapshot.memory.usedPercent,
                                tint: CareTheme.teal
                            ) { openProcesses(.memory) }
                            if let disk = snapshot.disks.first {
                                // No chevron, no dead button, when Storage is
                                // turned off by policy.
                                HUDMetric(
                                    label: "Storage",
                                    value: "\(ByteSizeFormatter.format(Int64(disk.total - disk.used))) available",
                                    percent: disk.usedPercent,
                                    tint: CareTheme.accent,
                                    action: ManagedPolicy.shared.isFeatureDisabled("analyze") ? nil : { navigate(.analyze) }
                                )
                            }
                            HStack {
                                if let gpu = snapshot.gpu.first, gpu.usage >= 0 {
                                    Label("GPU \(Int(gpu.usage))%", systemImage: "rectangle.3.group")
                                }
                                Spacer()
                                if let battery = snapshot.batteries.first {
                                    Label(
                                        "\(Int(battery.percent))%",
                                        systemImage: battery.status == "Discharging" ? "battery.75" : "battery.100.bolt"
                                    )
                                }
                            }.font(.caption2).foregroundStyle(CareTheme.secondaryInk)
                        }.padding(12).cardSurface(radius: 16)
                    } else {
                        ProgressView("Reading live activity…").font(.caption)
                            .frame(maxWidth: .infinity, minHeight: 110).cardSurface()
                    }
                    if let netInfo, ContentView.SidebarItem.visibleCases(developerTools: advancedTools).contains(.network) {
                        network(netInfo)
                    }
                    if let activity = work.activity {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(activity.title).font(.caption).lineLimit(2)
                            Spacer(minLength: 0)
                            if work.canCancel {
                                Button("Cancel", action: work.cancel).controlSize(.small)
                            }
                        }.padding(12).cardSurface(radius: 13)
                    }
                    shortcuts
                    if canPurgeMemory {
                        Button {
                            freeInactiveMemory()
                        } label: {
                            Label(freeingMemory ? "Freeing inactive memory…" : "Free inactive memory", systemImage: "memorychip")
                                .font(.caption)
                        }.buttonStyle(.plain).foregroundStyle(CareTheme.accent)
                            .disabled(work.isBusy || freeingMemory)
                            .help("Asks macOS to release inactive file cache. Nothing is removed from disk.")
                    }
                    if let memoryStatus {
                        Text(memoryStatus).font(.caption).foregroundStyle(CareTheme.secondaryInk)
                    }
                    if let snapshot = metrics.snapshot {
                        HStack {
                            Label(HealthScore.formatUptime(snapshot.uptimeSeconds), systemImage: "clock")
                            Spacer()
                            Text(snapshot.host).lineLimit(1)
                        }.font(.caption2).foregroundStyle(CareTheme.secondaryInk)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 14)
            }
            VStack(spacing: 12) {
                Button { navigate(.status) } label: {
                    HStack { Text("Open myKikau"); Spacer(); Image(systemName: "arrow.up.right") }
                }.carePrimaryAction()
                // With the Dock icon hidden there's no app menu, so About and
                // Check for Updates must be reachable from here.
                VStack(spacing: 8) {
                    HStack {
                        AppSettingsButton(dismissesSourceWindow: true) { Label("Settings…", systemImage: "gearshape") }
                        Spacer()
                        if updaterViewModel.updatesAvailable {
                            Button("Check for Updates…") {
                                NSApp.activate(ignoringOtherApps: true)
                                updaterViewModel.checkForUpdates()
                            }
                            .disabled(!updaterViewModel.canCheckForUpdates)
                        }
                    }
                    HStack {
                        Button("About myKikau") {
                            openWindow(id: "about")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        Spacer()
                        // Escape dismisses the popover; it never quits the app.
                        Button("Quit myKikau") { NSApp.terminate(nil) }
                            .disabled(work.isBusy)
                            .help(work.isBusy ? "Wait for the current task to finish, or cancel it, before quitting." : "")
                    }
                }.buttonStyle(.plain).font(.caption).foregroundStyle(CareTheme.secondaryInk)
            }.padding(16).background(CareTheme.panel)
        }
        .frame(width: 340, height: popoverHeight)
        .foregroundStyle(CareTheme.ink).background(CareTheme.background).tint(CareTheme.accent)
        .task {
            metrics.subscribe()
            copiedIP = false
            let info = await Task.detached(priority: .utility) { NetworkInfo.collect() }.value
            if !Task.isCancelled {
                netInfo = info
            }
        }
        .onDisappear { metrics.unsubscribe() }
    }

    private func status(_ snapshot: MetricsSnapshot) -> some View {
        let band = HealthScore.band(for: snapshot.healthScore)
        let parts = snapshot.healthScoreMsg.components(separatedBy: ": ")
        let detail = parts.count > 1 ? parts.dropFirst().joined(separator: ": ") : band.explanation
        return VStack(alignment: .leading, spacing: 7) {
            Label(band.word, systemImage: band.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(CareTheme.ink)
            Text(detail).font(.caption).foregroundStyle(CareTheme.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(CareTheme.lilac.opacity(0.55), in: RoundedRectangle(cornerRadius: 15))
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A LITTLE CARE").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(CareTheme.secondaryInk)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                if !ManagedPolicy.shared.isFeatureDisabled("clean") {
                    HUDShortcut("Clean up", detail: "Review everyday clutter", icon: "paintbrush.pointed", tint: CareTheme.accent) {
                        navigate(.clean)
                    }
                }
                if !ManagedPolicy.shared.isFeatureDisabled("uninstall") {
                    HUDShortcut("Applications", detail: "Apps & leftovers", icon: "square.grid.2x2", tint: CareTheme.teal) {
                        navigate(.uninstall)
                    }
                }
                if !ManagedPolicy.shared.isFeatureDisabled("optimize") {
                    HUDShortcut("System care", detail: "Checks & recommendations", icon: "wrench.and.screwdriver", tint: CareTheme.gold) {
                        navigate(.optimize)
                    }
                }
                if !ManagedPolicy.shared.isFeatureDisabled("clean") {
                    HUDShortcut("Review Trash", detail: "Choose exact items first", icon: "trash", tint: CareTheme.rose) {
                        AppNavigation.shared.pendingTrashReview = true
                        navigate(.clean)
                    }.disabled(work.isBusy)
                }
            }
        }
    }

    private func network(_ info: NetworkInfo) -> some View {
        HStack(spacing: 10) {
            Button { navigate(.network) } label: {
                HStack(spacing: 9) {
                    Image(systemName: info.isOnline ? "network" : "network.slash").foregroundStyle(CareTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.shortLabel).font(.caption.weight(.medium)).lineLimit(1)
                        Text(info.localIPv4 ?? "No local IP address").font(.caption2).monospaced().foregroundStyle(CareTheme.secondaryInk)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let ip = info.localIPv4 {
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ip, forType: .string); copiedIP = true
                } label: {
                    Image(systemName: copiedIP ? "checkmark" : "doc.on.doc").font(.caption)
                }.buttonStyle(.borderless).help(copiedIP ? "IP address copied" : "Copy local IP address")
                    .accessibilityLabel(copiedIP ? "IP address copied" : "Copy local IP address")
            }
        }.padding(12).cardSurface(radius: 13)
    }

    private func navigate(_ destination: ContentView.SidebarItem) {
        AppNavigation.shared.pendingSelection = destination
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
    }

    private func openProcesses(_ mode: ProcessMonitor.SortMode) {
        guard !DeletionActivity.shared.isRunning else { navigate(.status); return }
        AppNavigation.shared.pendingProcessMode = mode
        navigate(.status)
    }

    private func freeInactiveMemory() {
        guard !freeingMemory, let lease = work.begin("Releasing inactive file cache", kind: .maintenance) else { return }
        freeingMemory = true; memoryStatus = nil
        Task {
            defer { work.finish(lease); freeingMemory = false }
            memoryStatus = await MemoryOptimizer.freeInactiveMemory().message
        }
    }
}

private struct HUDShortcut: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, detail: String, icon: String, tint: Color, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.icon = icon; self.tint = tint; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(tint)
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(CareTheme.ink)
                }
                Text(detail).font(.caption2).foregroundStyle(CareTheme.secondaryInk).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(10).frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading).cardSurface(radius: 13)
                .opacity(enabled ? 1 : 0.5).contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain)
    }
}

private struct HUDMetric: View {
    let label: String
    let value: String
    let percent: Double
    let tint: Color
    var action: (() -> Void)?
    var body: some View {
        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            HStack {
                Text(label).font(.caption.weight(.medium))
                Spacer()
                Text(value).font(.caption).monospacedDigit().foregroundStyle(CareTheme.secondaryInk)
                if action !=
                    nil
                {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(CareTheme.secondaryInk)
                }
            }
            SizeBar(percent: percent, color: tint)
        }.contentShape(Rectangle())
    }
}
