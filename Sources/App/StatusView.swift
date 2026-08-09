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

                        LiveSignalsCard(snapshot: snap)

                        if !snap.network.isEmpty {
                            StatCard(title: "Network") {
                                ForEach(snap.network, id: \.name) { net in
                                    NetworkRow(net: net)
                                }
                            }
                        }

                        if !snap.gpu.isEmpty {
                            StatCard(title: "GPU") {
                                ForEach(snap.gpu, id: \.name) { gpu in
                                    GPURow(gpu: gpu)
                                }
                            }
                        }

                        let t = snap.thermal
                        if t.fanSpeed > 0 || t.batteryTemp > 0 || t.systemPower > 0 || t.adapterPower > 0 || t.batteryPower != 0 {
                            StatCard(title: "Thermal / Power") {
                                VStack(alignment: .leading, spacing: 4) {
                                    if t.fanSpeed > 0 {
                                        HStack {
                                            Text("Fan")
                                            Spacer()
                                            Text("\(t.fanSpeed) rpm")
                                                .monospacedDigit()
                                        }
                                    }
                                    if t.batteryTemp > 0 {
                                        HStack {
                                            Text("Battery temp")
                                            Spacer()
                                            Text(String(format: "%.1f °C", t.batteryTemp))
                                                .monospacedDigit()
                                        }
                                    }
                                    if t.systemPower > 0 {
                                        HStack {
                                            Text("System")
                                            Spacer()
                                            Text(String(format: "%.2f W", t.systemPower))
                                                .monospacedDigit()
                                        }
                                    }
                                    if t.adapterPower > 0 {
                                        HStack {
                                            Text("Adapter")
                                            Spacer()
                                            Text(String(format: "%.1f W", t.adapterPower))
                                                .monospacedDigit()
                                        }
                                    }
                                    if t.batteryPower != 0 {
                                        HStack {
                                            Text("Battery")
                                            Spacer()
                                            Text(String(format: "%.2f W", t.batteryPower))
                                                .monospacedDigit()
                                        }
                                    }
                                }
                                .font(.subheadline)
                            }
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

/// Minimal trend line for a bounded series of recent values (0–100 range).
/// Draws nothing (collapses to empty space) until there's more than one sample.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                Path { path in
                    let maxV = max(values.max() ?? 100, 1)
                    let stepX = geo.size.width / CGFloat(values.count - 1)
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height * (1 - CGFloat(v / maxV))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

/// Full dashboard scan, the "Smart Care"-equivalent single entry point.
private struct FullSystemScanCard: View {
    let onNavigate: (ContentView.SidebarItem) -> Void

    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Full System Scan", systemImage: "sparkle.magnifyingglass")
                    .font(.headline)
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

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    if let cleanPlans = coordinator.cleanPlans {
                        let cleanTotal = cleanPlans.values.reduce(Int64(0)) { $0 + $1.totalReclaimable }
                        SummaryPill(
                            title: "Clean",
                            value: ByteSizeFormatter.format(cleanTotal),
                            tint: ContentView.SidebarItem.clean.tint,
                            action: { onNavigate(.clean) }
                        )
                    }
                    if let apps = coordinator.apps {
                        SummaryPill(
                            title: "Apps",
                            value: "\(apps.count) · \(ByteSizeFormatter.format(coordinator.appFootprintBytes))",
                            tint: ContentView.SidebarItem.uninstall.tint,
                            action: { onNavigate(.uninstall) }
                        )
                    }
                    if let duplicateGroups = coordinator.duplicateGroups {
                        let total = duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
                        SummaryPill(
                            title: "Duplicates",
                            value: "\(duplicateGroups.count) · \(ByteSizeFormatter.format(total))",
                            tint: ContentView.SidebarItem.duplicates.tint,
                            action: { onNavigate(.duplicates) }
                        )
                    }
                    if let largeFiles = coordinator.largeFiles {
                        let total = largeFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
                        SummaryPill(
                            title: "Large Files",
                            value: "\(largeFiles.count) · \(ByteSizeFormatter.format(total))",
                            tint: ContentView.SidebarItem.analyze.tint,
                            action: {
                                AppNavigation.shared.pendingDuplicatesMode = "largeFiles"
                                onNavigate(.duplicates)
                            }
                        )
                    }
                }
            } else {
                Text("Scans cleanable data, installed apps, duplicates, and large user files, then sends each category to its review screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct LiveSignalsCard: View {
    let snapshot: MetricsSnapshot

    var body: some View {
        StatCard(title: "Live Signals") {
            VStack(spacing: 10) {
                CompactMetricRow(
                    icon: "cpu",
                    title: "CPU",
                    value: "\(Int(snapshot.cpu.usage))%",
                    percent: snapshot.cpu.usage,
                    color: .blue
                )
                CompactMetricRow(
                    icon: "memorychip",
                    title: "Memory",
                    value: "\(ByteSizeFormatter.format(Int64(snapshot.memory.available))) available",
                    percent: snapshot.memory.usedPercent,
                    color: SizeBar.color(for: snapshot.memory.usedPercent)
                )
                if let disk = snapshot.disks.first {
                    CompactMetricRow(
                        icon: "internaldrive",
                        title: disk.mount == "/" ? "Disk" : disk.mount,
                        value: "\(ByteSizeFormatter.format(Int64(disk.total - disk.used))) free",
                        percent: disk.usedPercent,
                        color: SizeBar.color(for: disk.usedPercent)
                    )
                }
                HStack {
                    Label(HealthScore.formatUptime(snapshot.uptimeSeconds), systemImage: "clock")
                    Spacer()
                    if let battery = snapshot.batteries.first {
                        Label("\(Int(battery.percent))% \(battery.status)", systemImage: battery.status == "Charging" ? "battery.100.bolt" : "battery.100")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CompactMetricRow: View {
    let icon: String
    let title: String
    let value: String
    let percent: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.subheadline)
                    Spacer()
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                SizeBar(percent: percent, color: color)
            }
        }
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

    private var statusWord: String {
        switch snapshot.healthScore {
        case 90...: "Great"
        case 75..<90: "Good"
        case 60..<75: "OK"
        default: "Needs Maintenance"
        }
    }

    private var statusExplanation: String {
        switch snapshot.healthScore {
        case 90...: "No urgent issues detected"
        case 75..<90: "Minor pressure detected"
        case 60..<75: "Some maintenance is worth reviewing"
        default: "Action recommended"
        }
    }

    /// Everything after the first ":" in e.g. "Fair: High CPU, Heavy Disk IO" —
    /// empty when the score has no active issues (message is just "Excellent").
    private var issuesDetail: String? {
        let parts = snapshot.healthScoreMsg.components(separatedBy: ": ")
        guard parts.count > 1 else { return nil }
        return parts.dropFirst().joined(separator: ": ")
    }

    private var statusColor: Color {
        switch snapshot.healthScore {
        case 85...: Color(red: 0.42, green: 0.94, blue: 0.86)
        case 65..<85: .yellow
        case 45..<65: .orange
        default: .red
        }
    }

    private var cpuValue: String {
        snapshot.thermal.cpuTemp > 0
            ? "\(Int(snapshot.cpu.usage))% load · \(String(format: "%.0f°C", snapshot.thermal.cpuTemp))"
            : "\(Int(snapshot.cpu.usage))% load"
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
                    Text(snapshot.host)
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
                    actionLabel: freeingMemory ? "Freeing..." : "Free Up",
                    action: onFreeMemory,
                    secondaryActionLabel: "View",
                    secondaryAction: onShowMemory,
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
            }

            if let memoryActionMessage {
                Text(memoryActionMessage)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            }

            if let net = snapshot.network.first(where: { $0.rxRateMBs > 0 || $0.txRateMBs > 0 }) ?? snapshot.network.first {
                HStack(spacing: 16) {
                    Label(net.name, systemImage: "wifi")
                    Spacer()
                    Text("↓ \(String(format: "%.1f", net.rxRateMBs)) MB/s")
                    Text("↑ \(String(format: "%.1f", net.txRateMBs)) MB/s")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 4)
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
}

private struct ProcessListSheet: View {
    let mode: ProcessMonitor.SortMode
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ProcessMonitor.ProcessInfo] = []
    @State private var loading = true

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
                Button("Refresh") { load() }
                Button("Done") { dismiss() }
            }
            .padding()

            if loading {
                ProgressView("Collecting processes...")
                    .frame(width: 520, height: 320)
            } else {
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
                    }
                }
                .frame(width: 560, height: 360)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        loading = true
        Task {
            let result = await ProcessMonitor.top(sort: mode)
            await MainActor.run {
                rows = result
                loading = false
            }
        }
    }
}

/// A single glass-morphic stat tile inside `HeroHealthCard`.
private struct GlassTile: View {
    let icon: String
    let title: String
    let value: String
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
                .foregroundStyle(.white)
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
                .foregroundStyle(Color(red: 0.42, green: 0.94, blue: 0.86))
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

private struct MetricRow: View {
    let label: String
    let percent: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(ByteSizeFormatter.formatPercent(percent))
                    .font(.subheadline)
                    .monospacedDigit()
            }
            SizeBar(percent: percent, color: color)
        }
    }
}

private struct NetworkRow: View {
    let net: NetworkStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(net.name).font(.subheadline)
                Spacer()
                if !net.ip.isEmpty {
                    Text(net.ip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            HStack {
                Text("↓ \(String(format: "%.2f", net.rxRateMBs)) MB/s")
                Spacer()
                Text("↑ \(String(format: "%.2f", net.txRateMBs)) MB/s")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

private struct GPURow: View {
    let gpu: GPUStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(gpu.name).font(.subheadline)
                Spacer()
                Text(gpu.usage >= 0 ? String(format: "%.0f%%", gpu.usage) : "N/A")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(gpu.usage >= 0 ? .primary : .secondary)
            }
            if !gpu.note.isEmpty {
                Text(gpu.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if gpu.coreCount > 0 {
                Text("\(gpu.coreCount) cores")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if gpu.usage < 0 {
                Text("Live usage needs admin privileges myKikau doesn't request — everything else here is accurate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
