import AppKit
import SwiftUI
import Core
import Features
import UI

struct StatusView: View {
    /// Lets the dashboard jump straight to another sidebar screen.
    var onNavigate: (ContentView.SidebarItem) -> Void = { _ in }

    @ObservedObject private var metricsService = MetricsService.shared
    @State private var totalFreed: Int64 = 0
    @State private var hasFullDiskAccess = FullDiskAccessCheck.probe()
    @State private var freeingMemory = false
    @State private var memoryActionMessage: String?
    @State private var processSheet: ProcessSheet?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("System Status").font(.title2).bold()
                Spacer()
                if totalFreed > 0 {
                    Label(ByteSizeFormatter.format(totalFreed) + " freed to date", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top])

            if !hasFullDiskAccess {
                FullDiskAccessBanner()
                    .padding(.horizontal)
            }

            if let snap = metricsService.snapshot {
                ScrollView {
                    VStack(spacing: 12) {
                        HeroHealthCard(
                            snapshot: snap,
                            onNavigate: onNavigate,
                            freeingMemory: freeingMemory,
                            memoryActionMessage: memoryActionMessage,
                            onFreeMemory: freeInactiveMemory,
                            onShowCPU: { processSheet = ProcessSheet(mode: .cpu) },
                            onShowMemory: { processSheet = ProcessSheet(mode: .memory) }
                        )

                        FullSystemScanCard(onNavigate: onNavigate)

                        if !snap.network.isEmpty {
                            NetworkGraphCard(current: snap.network, history: metricsService.history)
                        }
                    }
                    .padding()
                }
            } else {
                ProgressView("Collecting metrics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            metricsService.subscribe()
            totalFreed = OperationLog.shared.totalFreed()
            hasFullDiskAccess = FullDiskAccessCheck.probe()
        }
        .onDisappear { metricsService.unsubscribe() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccessCheck.probe()
        }
        .onReceive(AppNavigation.shared.$pendingProcessMode) { pending in
            guard let pending else { return }
            processSheet = ProcessSheet(mode: pending)
            AppNavigation.shared.pendingProcessMode = nil
        }
        .sheet(item: $processSheet) { sheet in
            ProcessListSheet(mode: sheet.mode)
        }
    }

    private func freeInactiveMemory() {
        guard !freeingMemory else { return }
        freeingMemory = true
        memoryActionMessage = nil
        Task {
            let result = await MemoryOptimizer.freeInactiveMemory()
            await MainActor.run {
                freeingMemory = false
                memoryActionMessage = result.message
            }
        }
    }
}

private struct ProcessSheet: Identifiable {
    let id = UUID()
    let mode: ProcessMonitor.SortMode
}

/// Network throughput card: a live download/upload graph over the shared
/// `MetricsService.history` window (~2 minutes at the 2s poll interval),
/// replacing the old plain per-interface number list — the shape of the
/// traffic over time (a download burst vs. steady background chatter) is
/// what's actually useful to see, not just the instantaneous rate.
private struct NetworkGraphCard: View {
    let current: [NetworkStatus]
    let history: [MetricsSnapshot]

    private var rxHistory: [Double] { history.map { snap in snap.network.reduce(0) { $0 + $1.rxRateMBs } } }
    private var txHistory: [Double] { history.map { snap in snap.network.reduce(0) { $0 + $1.txRateMBs } } }
    private var totalRx: Double { current.reduce(0) { $0 + $1.rxRateMBs } }
    private var totalTx: Double { current.reduce(0) { $0 + $1.txRateMBs } }

    /// The interface actually carrying traffic, for the small label under the
    /// graph — falls back to the first known interface when everything's idle.
    private var activeInterface: NetworkStatus? {
        current.first(where: { $0.rxRateMBs > 0 || $0.txRateMBs > 0 }) ?? current.first
    }

    var body: some View {
        StatCard(title: "Network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Label(String(format: "%.2f MB/s", totalRx), systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                    Label(String(format: "%.2f MB/s", totalTx), systemImage: "arrow.up")
                        .foregroundStyle(.green)
                    Spacer()
                    if let net = activeInterface {
                        Text(net.ip.isEmpty ? net.name : "\(net.name) · \(net.ip)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.bold())
                .monospacedDigit()

                DualSparkline(primary: rxHistory, secondary: txHistory, primaryColor: .blue, secondaryColor: .green)
                    .frame(height: 56)
            }
        }
    }
}

/// Two overlaid trend lines sharing one normalized scale — used for the
/// network graph's download/upload pair. Draws nothing (collapses to empty
/// space) until there's more than one sample.
private struct DualSparkline: View {
    let primary: [Double]
    let secondary: [Double]
    let primaryColor: Color
    let secondaryColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.4))
                // Floor the scale so a fully idle window (all-zero history)
                // doesn't divide-by-near-zero into a jittery flat line.
                let maxV = max(primary.max() ?? 0, secondary.max() ?? 0, 0.05)
                line(for: primary, maxV: maxV, size: geo.size)
                    .stroke(primaryColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                line(for: secondary, maxV: maxV, size: geo.size)
                    .stroke(secondaryColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func line(for values: [Double], maxV: Double, size: CGSize) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            let stepX = size.width / CGFloat(values.count - 1)
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(v / maxV))
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}

/// Full dashboard scan, the "Smart Care"-equivalent single entry point.
/// Styled to match `HeroHealthCard`'s level of polish — an icon badge in the
/// header, and (before the first scan) a preview grid of what it actually
/// checks, so the card sells its own value instead of hiding behind one line
/// of caption text.
private struct FullSystemScanCard: View {
    let onNavigate: (ContentView.SidebarItem) -> Void

    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared

    private static let categories: [ScanCategory] = [
        ScanCategory(icon: "internaldrive", title: "Clean", subtitle: "Cache & junk files", tint: ContentView.SidebarItem.clean.tint),
        ScanCategory(icon: "app.dashed", title: "Apps", subtitle: "Installed applications", tint: ContentView.SidebarItem.uninstall.tint),
        ScanCategory(icon: "doc.on.doc", title: "Duplicates", subtitle: "Repeated files", tint: ContentView.SidebarItem.duplicates.tint),
        ScanCategory(icon: "chart.bar.doc.horizontal", title: "Large Files", subtitle: "Space hogs", tint: ContentView.SidebarItem.analyze.tint)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        LinearGradient(colors: [.accentColor, .accentColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full System Scan").font(.headline)
                    Text("One scan across cache, apps, duplicates, and large files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(coordinator.isScanning ? "Scanning…" : (coordinator.hasResults ? "Rescan" : "Scan")) {
                    Task { await coordinator.scanEverything() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isScanning)
            }

            if coordinator.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView()
                    Text("Scanning cleanable data, apps, duplicate files, and large user files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if coordinator.hasResults {
                Text("\(coordinator.combinedItemCount) items · \(ByteSizeFormatter.format(coordinator.combinedReclaimableBytes)) reclaimable")
                    .font(.title3.bold())
                    .foregroundStyle(coordinator.combinedReclaimableBytes > 0 ? Color.green : .secondary)
                if let lastScanAt = coordinator.lastScanAt {
                    Text("Last scanned \(lastScanAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    if let cleanPlans = coordinator.cleanPlans {
                        let cleanTotal = cleanPlans.values.reduce(Int64(0)) { $0 + $1.totalReclaimable }
                        SummaryPill(
                            icon: "internaldrive",
                            title: "Clean",
                            value: ByteSizeFormatter.format(cleanTotal),
                            tint: ContentView.SidebarItem.clean.tint,
                            action: { onNavigate(.clean) }
                        )
                    }
                    if let apps = coordinator.apps {
                        SummaryPill(
                            icon: "app.dashed",
                            title: "Apps",
                            value: "\(apps.count) · \(ByteSizeFormatter.format(coordinator.appFootprintBytes))",
                            tint: ContentView.SidebarItem.uninstall.tint,
                            action: { onNavigate(.uninstall) }
                        )
                    }
                    if let duplicateGroups = coordinator.duplicateGroups {
                        let total = duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
                        SummaryPill(
                            icon: "doc.on.doc",
                            title: "Duplicates",
                            value: "\(duplicateGroups.count) · \(ByteSizeFormatter.format(total))",
                            tint: ContentView.SidebarItem.duplicates.tint,
                            action: { onNavigate(.duplicates) }
                        )
                    }
                    if let largeFiles = coordinator.largeFiles {
                        let total = largeFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
                        SummaryPill(
                            icon: "chart.bar.doc.horizontal",
                            title: "Large Files",
                            value: "\(largeFiles.count) · \(ByteSizeFormatter.format(total))",
                            tint: ContentView.SidebarItem.analyze.tint,
                            action: {
                                AppNavigation.shared.pendingDuplicatesMode = .largeFiles
                                onNavigate(.duplicates)
                            }
                        )
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(Self.categories) { category in
                        ScanCategoryChip(category: category)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One of the things a Full System Scan checks, shown as a preview chip
/// before the first scan runs so the card explains itself without the user
/// having to press "Scan" first to find out.
private struct ScanCategory: Identifiable {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    var id: String { title }
}

private struct ScanCategoryChip: View {
    let category: ScanCategory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(category.tint)
                .frame(width: 30, height: 30)
                .background(category.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).font(.caption.bold())
                Text(category.subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SummaryPill: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Persistent reminder for users who skipped granting access during onboarding.
private struct FullDiskAccessBanner: View {
    var body: some View {
        HStack {
            Label("Full Disk Access isn't granted — some cleanup and analysis features will under-report or fail.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button("Open Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Premium "hero" card modeled on CleanMyMac's dashboard widget: a dark
/// gradient card with the headline health score up top and a grid of glass
/// tiles for the numbers people actually glance at first — storage, memory,
/// battery, CPU — each with a one-tap way to act where that makes sense.
/// Everything below this (Scan Everything, Quick Actions, detailed per-metric
/// cards) is still the system-styled, information-dense app; this is
/// deliberately the one branded, designed moment at the top of the page.
private struct HeroHealthCard: View {
    let snapshot: MetricsSnapshot
    let onNavigate: (ContentView.SidebarItem) -> Void
    let freeingMemory: Bool
    let memoryActionMessage: String?
    let onFreeMemory: () -> Void
    let onShowCPU: () -> Void
    let onShowMemory: () -> Void
    private let canPurgeMemory = MemoryOptimizer.isPurgeAvailable()

    /// Word, explanation, and color, from the one canonical band definition
    /// in `HealthScore` — also used by the menu bar HUD, so the two can't
    /// drift out of sync the way they used to (each had its own hand-rolled
    /// bands, and neither one's word/color bands actually lined up).
    private var healthBand: HealthScore.Band { HealthScore.band(for: snapshot.healthScore) }

    private var statusWord: String { healthBand.word }
    private var statusExplanation: String { healthBand.explanation }
    private var statusColor: Color { healthBand.color }

    /// Everything after the first ":" in e.g. "Fair: High CPU, Heavy Disk IO" —
    /// empty when the score has no active issues (message is just "Excellent").
    private var issuesDetail: String? {
        let parts = snapshot.healthScoreMsg.components(separatedBy: ": ")
        guard parts.count > 1 else { return nil }
        return parts.dropFirst().joined(separator: ": ")
    }

    private var cpuValue: String {
        "\(Int(snapshot.cpu.usage))% load"
    }

    /// GPU usage isn't always readable (see `GPUMonitor` — needs an
    /// `IOAccelerator` key macOS doesn't expose on every GPU/OS combination),
    /// so fall back to core count alone rather than showing a bare "N/A".
    private func gpuValue(_ gpu: GPUStatus) -> String {
        if gpu.usage >= 0 {
            return gpu.coreCount > 0 ? "\(Int(gpu.usage))% · \(gpu.coreCount) cores" : "\(Int(gpu.usage))%"
        }
        return gpu.coreCount > 0 ? "\(gpu.coreCount) cores" : "N/A"
    }

    /// Rolls up the old separate "Thermal / Power" card into one tile: CPU
    /// die temp as the headline (falling back to battery temp on Intel,
    /// where `CPUTemperatureMonitor` can't read the die sensors), with fan
    /// speed and system power draw — the two next-most-telling "is this Mac
    /// working hard" signals — as a caption. Adapter/battery wattage are
    /// dropped rather than crammed in; that's charging detail, not thermal.
    private var hasThermalSignal: Bool {
        let t = snapshot.thermal
        return t.cpuTemp > 0 || t.batteryTemp > 0 || t.fanSpeed > 0 || t.systemPower > 0
    }

    private var temperatureValue: String {
        let t = snapshot.thermal
        if t.cpuTemp > 0 { return String(format: "%.0f°C", t.cpuTemp) }
        if t.batteryTemp > 0 { return String(format: "%.0f°C", t.batteryTemp) }
        return "N/A"
    }

    private var temperatureCaption: String? {
        let t = snapshot.thermal
        var parts: [String] = []
        if t.fanSpeed > 0 { parts.append("Fan \(t.fanSpeed) rpm") }
        if t.systemPower > 0 { parts.append(String(format: "%.0fW draw", t.systemPower)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Green/yellow/red banding matching `HealthScore`'s recalibrated
    /// Apple-Silicon thermal thresholds (85°C normal ceiling, 100°C high),
    /// so a glance at the tile alone tells you whether a reading is routine.
    private var temperatureColor: Color {
        let t = snapshot.thermal
        let temp = t.cpuTemp > 0 ? t.cpuTemp : t.batteryTemp
        switch temp {
        case ..<85: return .white
        case 85..<100: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac Health")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(statusWord)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(statusColor)
                    }
                    Text("\(snapshot.host) · up \(HealthScore.formatUptime(snapshot.uptimeSeconds))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                    if let issuesDetail {
                        Text(issuesDetail)
                            .font(.caption2)
                            .foregroundStyle(statusColor.opacity(0.9))
                    } else {
                        Text(statusExplanation)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Text("Based on CPU, memory pressure, disk space, temperature, disk activity, battery, and uptime.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.08), in: Circle())
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                if let disk = snapshot.disks.first {
                    GlassTile(
                        icon: "internaldrive.fill",
                        title: disk.mount == "/" ? "Macintosh HD" : disk.mount,
                        value: "\(ByteSizeFormatter.format(Int64(disk.total - disk.used))) free",
                        actionLabel: "Free Up",
                        action: { onNavigate(.clean) }
                    )
                }
                GlassTile(
                    icon: "memorychip.fill",
                    title: "Memory",
                    value: "\(Int(snapshot.memory.usedPercent))% used · \(snapshot.memory.pressure)",
                    actionLabel: memoryActionLabel,
                    action: canPurgeMemory ? onFreeMemory : onShowMemory,
                    secondaryActionLabel: canPurgeMemory ? "View" : nil,
                    secondaryAction: canPurgeMemory ? onShowMemory : nil,
                    isBusy: freeingMemory
                )
                if let battery = snapshot.batteries.first {
                    GlassTile(
                        icon: battery.status == "Charging" ? "battery.100.bolt" : "battery.100",
                        title: "Battery",
                        value: "\(Int(battery.percent))% · \(battery.status)"
                    )
                }
                GlassTile(
                    icon: "cpu.fill",
                    title: "CPU",
                    value: cpuValue,
                    actionLabel: "View",
                    action: onShowCPU
                )
                if hasThermalSignal {
                    GlassTile(
                        icon: "thermometer.medium",
                        title: "Temperature",
                        value: temperatureValue,
                        valueColor: temperatureColor,
                        caption: temperatureCaption
                    )
                }
                if let gpu = snapshot.gpu.first {
                    GlassTile(
                        icon: "rectangle.3.group.fill",
                        title: "GPU",
                        value: gpuValue(gpu)
                    )
                }
            }

            if let memoryActionMessage {
                Text(memoryActionMessage)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.20, green: 0.11, blue: 0.42), Color(red: 0.08, green: 0.05, blue: 0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private var memoryActionLabel: String {
        if freeingMemory { return "Freeing..." }
        return canPurgeMemory ? "Free Up" : "View Usage"
    }
}

private struct ProcessListSheet: View {
    let mode: ProcessMonitor.SortMode
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ProcessMonitor.ProcessInfo] = []
    @State private var loading = true
    @State private var actionMessage: String?
    @State private var confirmQuit: ProcessMonitor.ProcessInfo?

    private var title: String {
        switch mode {
        case .cpu: "Top CPU Processes"
        case .memory: "Top Memory Processes"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Button("Activity Monitor") { openActivityMonitor() }
                Button("Refresh") { load() }
                Button("Done") { dismiss() }
            }
            .padding()

            if loading {
                ProgressView("Collecting processes...")
                    .frame(width: 520, height: 320)
            } else {
                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }
                List(rows) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.command)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Text("PID \(row.pid)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode == .memory {
                            Text(ByteSizeFormatter.format(row.residentBytes))
                                .font(.caption.bold())
                                .monospacedDigit()
                                .foregroundStyle(.purple)
                                .frame(width: 86, alignment: .trailing)
                            Text(String(format: "%.1f%% MEM", row.memoryPercent))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                        } else {
                            Text(String(format: "%.1f%% CPU", row.cpuPercent))
                                .font(.caption.bold())
                                .monospacedDigit()
                                .foregroundStyle(.blue)
                                .frame(width: 76, alignment: .trailing)
                            Text(ByteSizeFormatter.format(row.residentBytes))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 82, alignment: .trailing)
                        }
                        Button("Quit") {
                            confirmQuit = row
                        }
                        .disabled(!canQuit(row))
                    }
                }
                .frame(width: 640, height: 380)
            }
        }
        .onAppear { load() }
        .confirmationDialog(
            "Quit \(confirmQuit?.command ?? "process")?",
            isPresented: Binding(
                get: { confirmQuit != nil },
                set: { if !$0 { confirmQuit = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let row = confirmQuit {
                Button("Quit \(row.command)", role: .destructive) {
                    quit(row)
                    confirmQuit = nil
                }
            }
            Button("Cancel", role: .cancel) {
                confirmQuit = nil
            }
        } message: {
            Text("This asks the app to quit normally. Unsaved work in that app may be lost if it does not handle quit cleanly.")
        }
    }

    private func load() {
        loading = true
        actionMessage = nil
        Task {
            let result = await ProcessMonitor.top(sort: mode)
            await MainActor.run {
                rows = result
                loading = false
            }
        }
    }

    private func canQuit(_ row: ProcessMonitor.ProcessInfo) -> Bool {
        guard row.pid != Int(Foundation.ProcessInfo.processInfo.processIdentifier),
              let app = NSRunningApplication(processIdentifier: pid_t(row.pid)) else {
            return false
        }
        return !app.isTerminated
    }

    private func quit(_ row: ProcessMonitor.ProcessInfo) {
        guard let app = NSRunningApplication(processIdentifier: pid_t(row.pid)) else {
            actionMessage = "\(row.command) is no longer running."
            load()
            return
        }
        let appName = app.localizedName ?? row.command
        if app.terminate() {
            actionMessage = "Asked \(appName) to quit."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                load()
            }
        } else {
            actionMessage = "\(appName) did not accept the quit request. Open Activity Monitor for force quit options."
        }
    }

    private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                DispatchQueue.main.async {
                    actionMessage = "Could not open Activity Monitor: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// A single glass-morphic stat tile inside `HeroHealthCard`.
private struct GlassTile: View {
    let icon: String
    let title: String
    let value: String
    var valueColor: Color = .white
    var caption: String?
    var actionLabel: String?
    var action: (() -> Void)?
    var secondaryActionLabel: String?
    var secondaryAction: (() -> Void)?
    var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.white.opacity(0.85))
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(valueColor)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            if actionLabel != nil || secondaryActionLabel != nil {
                HStack(spacing: 10) {
                    if let actionLabel, let action {
                        Button(actionLabel, action: action)
                            .disabled(isBusy)
                    }
                    if let secondaryActionLabel, let secondaryAction {
                        Button(secondaryActionLabel, action: secondaryAction)
                    }
                }
                .font(.caption.bold())
                .buttonStyle(.plain)
                .foregroundStyle(HealthScore.accentTeal)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 92, alignment: .topLeading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

private struct StatCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

