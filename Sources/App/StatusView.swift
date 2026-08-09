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
                        HeroHealthCard(snapshot: snap, onNavigate: onNavigate)

                        ScanEverythingCard(onNavigate: onNavigate)

                        QuickActionsGrid(onNavigate: onNavigate)

                        StatCard(title: "CPU") {
                            MetricRow(label: "Usage", percent: snap.cpu.usage, color: .blue)
                            Sparkline(values: metricsService.history.map(\.cpu.usage), color: .blue)
                                .frame(height: 28)
                            if !snap.cpu.perCore.isEmpty {
                                Text("\(snap.cpu.logicalCPU) logical cores")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        StatCard(title: "Memory") {
                            MetricRow(label: "Used", percent: snap.memory.usedPercent,
                                      color: SizeBar.color(for: snap.memory.usedPercent))
                            Sparkline(values: metricsService.history.map(\.memory.usedPercent), color: .purple)
                                .frame(height: 28)
                            HStack {
                                Text("Used \(ByteSizeFormatter.format(Int64(snap.memory.used)))")
                                Spacer()
                                Text("Total \(ByteSizeFormatter.format(Int64(snap.memory.total)))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        StatCard(title: "Disk") {
                            ForEach(snap.disks, id: \.mount) { disk in
                                MetricRow(label: disk.mount, percent: disk.usedPercent,
                                          color: SizeBar.color(for: disk.usedPercent))
                            }
                        }

                        HStack(spacing: 12) {
                            StatCard(title: "Uptime") {
                                Text(HealthScore.formatUptime(snap.uptimeSeconds))
                                    .font(.title3)
                                    .monospacedDigit()
                            }
                            if let battery = snap.batteries.first {
                                StatCard(title: "Battery") {
                                    Text("\(Int(battery.percent))%")
                                        .font(.title3)
                                        .monospacedDigit()
                                    Text(battery.status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

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

                        if snap.diskIO.readRate > 0 || snap.diskIO.writeRate > 0 {
                            StatCard(title: "Disk IO") {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("↓ Read")
                                        Spacer()
                                        Text(String(format: "%.2f MB/s", snap.diskIO.readRate))
                                            .monospacedDigit()
                                    }
                                    HStack {
                                        Text("↑ Write")
                                        Spacer()
                                        Text(String(format: "%.2f MB/s", snap.diskIO.writeRate))
                                            .monospacedDigit()
                                    }
                                }
                                .font(.subheadline)
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
    }
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

/// Combined Clean + Purge scan, the "Smart Care"-equivalent single entry point.
private struct ScanEverythingCard: View {
    let onNavigate: (ContentView.SidebarItem) -> Void

    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Scan Everything", systemImage: "sparkle.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button(coordinator.isScanning ? "Scanning…" : (coordinator.hasResults ? "Rescan" : "Scan")) {
                    Task { await coordinator.scanEverything() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isScanning)
            }

            if coordinator.isScanning {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if coordinator.hasResults {
                Text("\(coordinator.combinedItemCount) items · \(ByteSizeFormatter.format(coordinator.combinedReclaimableBytes)) reclaimable")
                    .font(.title3.bold())
                    .foregroundStyle(coordinator.combinedReclaimableBytes > 0 ? Color.green : .secondary)

                HStack(spacing: 12) {
                    if let cleanPlans = coordinator.cleanPlans {
                        let cleanTotal = cleanPlans.values.reduce(Int64(0)) { $0 + $1.totalReclaimable }
                        Button("Review Clean (\(ByteSizeFormatter.format(cleanTotal)))") {
                            onNavigate(.clean)
                        }
                        .tint(ContentView.SidebarItem.clean.tint)
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Text("Scans caches, logs, and trash in one pass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Dashboard hub — one card per feature screen, launched from Status.
private struct QuickActionsGrid: View {
    let onNavigate: (ContentView.SidebarItem) -> Void

    private let actions: [(item: ContentView.SidebarItem, title: String, subtitle: String)] = [
        (.clean, "Clean", "Caches, logs & trash"),
        (.uninstall, "Uninstall", "Apps & their leftovers"),
        (.analyze, "Analyse", "Find what's using space"),
        (.duplicates, "Duplicates", "Duplicate & large files"),
        (.optimize, "Optimise", "10 maintenance tasks"),
        (.about, "About", "Version, updates & log"),
    ]

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions").font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(actions, id: \.item) { action in
                    Button {
                        onNavigate(action.item)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(action.item.tint.opacity(0.15))
                                    .frame(width: 34, height: 34)
                                Image(systemName: action.item.icon)
                                    .foregroundStyle(action.item.tint)
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            Text(action.title)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text(action.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
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

    private var statusWord: String {
        snapshot.healthScoreMsg.components(separatedBy: ":").first ?? snapshot.healthScoreMsg
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
                        Text("· \(snapshot.healthScore)/100")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(snapshot.host)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                    if let issuesDetail {
                        Text(issuesDetail)
                            .font(.caption2)
                            .foregroundStyle(statusColor.opacity(0.9))
                    }
                    Text("Combines CPU load, memory pressure, disk space, temperature & battery wear into one score.")
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
                    value: "\(Int(snapshot.memory.usedPercent))% used",
                    actionLabel: "Free Up",
                    action: { onNavigate(.clean) }
                )
                if let battery = snapshot.batteries.first {
                    GlassTile(
                        icon: battery.status == "Charging" ? "battery.100.bolt" : "battery.100",
                        title: "Battery",
                        value: "\(Int(battery.percent))% · \(battery.status)"
                    )
                }
                GlassTile(icon: "cpu.fill", title: "CPU", value: cpuValue)
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

/// A single glass-morphic stat tile inside `HeroHealthCard`.
private struct GlassTile: View {
    let icon: String
    let title: String
    let value: String
    var actionLabel: String?
    var action: (() -> Void)?

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
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(.caption.bold())
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.42, green: 0.94, blue: 0.86))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
