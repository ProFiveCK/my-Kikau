import AppKit
import Charts
import SwiftUI
import Core
import Features
import UI

struct StatusView: View {
    /// Lets the dashboard jump straight to another sidebar screen.
    var onNavigate: (ContentView.SidebarItem) -> Void = { _ in }

    @ObservedObject private var metricsService = MetricsService.shared
    @State private var showingActivity = false
    @State private var activityProcessSheet: ProcessSheet?
    @State private var freeingMemory = false
    @State private var memoryActionMessage: String?
    @State private var processSheet: ProcessSheet?

    var body: some View {
        CareHubView(onNavigate: onNavigate, onShowActivity: { showingActivity = true })
            .sheet(isPresented: $showingActivity) {
                VStack(spacing: 0) {
                    CareWindowHeader("Live activity", subtitle: "Current readings from your Mac") {
                        Button("Done") { showingActivity = false }.carePrimaryAction()
                    }
                    if let snap = metricsService.snapshot {
                        ScrollView {
                            HeroHealthCard(
                                snapshot: snap,
                                history: metricsService.history,
                                onNavigate: { target in showingActivity = false; onNavigate(target) },
                                freeingMemory: freeingMemory,
                                memoryActionMessage: memoryActionMessage,
                                onFreeMemory: freeInactiveMemory,
                                onShowCPU: { activityProcessSheet = ProcessSheet(mode: .cpu) },
                                onShowMemory: { activityProcessSheet = ProcessSheet(mode: .memory) }
                            ).padding()
                        }
                    } else {
                        ProgressView("Collecting metrics…").padding(60)
                    }
                }
                .frame(width: 720, height: 620).careScreen()
                .sheet(item: $activityProcessSheet) { ProcessListSheet(mode: $0.mode) }
            }
            .onAppear {
                metricsService.subscribe()
            }
            .onDisappear { metricsService.unsubscribe() }
            .onReceive(AppNavigation.shared.$pendingProcessMode) { pending in
                guard let pending else { return }
                if showingActivity {
                    activityProcessSheet = ProcessSheet(mode: pending)
                } else {
                    processSheet = ProcessSheet(mode: pending)
                }
                AppNavigation.shared.pendingProcessMode = nil
            }
            .sheet(item: $processSheet) { sheet in
                ProcessListSheet(mode: sheet.mode)
            }
    }

    private func freeInactiveMemory() {
        guard !freeingMemory, let lease = WorkCoordinator.shared.begin("Releasing inactive file cache", kind: .maintenance) else { return }
        freeingMemory = true
        memoryActionMessage = nil
        Task {
            defer { WorkCoordinator.shared.finish(lease) }
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

/// Detailed live monitoring, opened from Care hub’s Live activity action.
private struct HeroHealthCard: View {
    let snapshot: MetricsSnapshot
    let history: [MetricsService.Sample]
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
    private var healthBand: HealthScore.Band {
        HealthScore.band(for: snapshot.healthScore)
    }

    private var statusWord: String {
        healthBand.word
    }

    private var statusExplanation: String {
        healthBand.explanation
    }

    private var statusColor: Color {
        healthBand.color
    }

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
        if t.cpuTemp > 0 {
            return String(format: "%.0f°C", t.cpuTemp)
        }
        if t.batteryTemp > 0 {
            return String(format: "%.0f°C", t.batteryTemp)
        }
        return "N/A"
    }

    private var temperatureCaption: String? {
        let t = snapshot.thermal
        var parts: [String] = []
        if t.fanSpeed > 0 {
            parts.append("Fan \(t.fanSpeed) rpm")
        }
        if t.systemPower > 0 {
            parts.append(String(format: "%.0fW draw", t.systemPower))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Green/yellow/red banding matching `HealthScore`'s recalibrated
    /// Apple-Silicon thermal thresholds (85°C normal ceiling, 100°C high),
    /// so a glance at the tile alone tells you whether a reading is routine.
    private var temperatureColor: Color {
        let t = snapshot.thermal
        let temp = t.cpuTemp > 0 ? t.cpuTemp : t.batteryTemp
        switch temp {
        case ..<85: return CareTheme.ink
        case 85 ..< 100: return .yellow
        default: return .red
        }
    }

    /// Replaced the old standalone "Network" card (a full-width graph below
    /// this one) with a compact tile in the same grid as everything else —
    /// user feedback was that the graph wasn't earning its keep as its own
    /// section. Combined throughput is still one glance away; a trend line
    /// wasn't adding anything a plain rate number didn't already say.
    private var networkValue: String {
        let net = snapshot.network
        let rx = net.reduce(0) { $0 + $1.rxRateMBs }
        let tx = net.reduce(0) { $0 + $1.txRateMBs }
        return String(format: "↓%.1f · ↑%.1f MB/s", rx, tx)
    }

    private var networkCaption: String? {
        let net = snapshot.network
        let active = net.first(where: { $0.rxRateMBs > 0 || $0.txRateMBs > 0 }) ?? net.first
        return active?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 18))
                    .foregroundStyle(CareTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(CareTheme.lilac, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Current activity")
                            .font(.subheadline)
                            .foregroundStyle(CareTheme.secondaryInk)
                        Text(statusWord)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(CareTheme.ink)
                    }
                    .accessibilityElement(children: .combine)
                    Text(issuesDetail ?? statusExplanation)
                        .font(.caption)
                        .foregroundStyle(CareTheme.secondaryInk)
                }
                Spacer()
                Text("\(snapshot.host) · up \(HealthScore.formatUptime(snapshot.uptimeSeconds))")
                    .font(.caption)
                    .foregroundStyle(CareTheme.secondaryInk)
            }
            .help("Based on CPU, memory pressure, disk space, temperature, disk activity, battery, and uptime.")

            // As many columns as fit: three on a normal window, two when narrow.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
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
                    trend: history.map(\.memoryPercent),
                    actionLabel: memoryActionLabel,
                    action: canPurgeMemory ? onFreeMemory : onShowMemory,
                    secondaryActionLabel: canPurgeMemory ? "View" : nil,
                    secondaryAction: canPurgeMemory ? onShowMemory : nil,
                    isBusy: freeingMemory
                )
                if let battery = snapshot.batteries.first {
                    GlassTile(
                        icon: battery.status == "Discharging" ? "battery.75" : "battery.100.bolt",
                        title: "Battery",
                        value: "\(Int(battery.percent))% · \(battery.status)",
                        caption: batteryCaption(battery)
                    )
                }
                GlassTile(
                    icon: "cpu.fill",
                    title: "CPU",
                    value: cpuValue,
                    trend: history.map(\.cpuPercent),
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
                if !snapshot.network.isEmpty {
                    GlassTile(
                        icon: "network",
                        title: "Network",
                        value: networkValue,
                        caption: networkCaption
                    )
                }
            }

            if let memoryActionMessage {
                Text(memoryActionMessage)
                    .font(.caption2)
                    .foregroundStyle(CareTheme.secondaryInk)
            }
        }
        .padding(14)
        .cardSurface(radius: 18)
    }

    /// Wear: full-charge capacity against design capacity, and cycle count.
    private func batteryCaption(_ battery: BatteryStatus) -> String? {
        var parts: [String] = []
        if battery.capacity > 0 {
            parts.append("Health \(battery.capacity)%")
        }
        if battery.cycleCount > 0 {
            parts.append("\(battery.cycleCount) cycles")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var memoryActionLabel: String {
        if freeingMemory {
            return "Freeing..."
        }
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
            CareWindowHeader(title, subtitle: "Inspect usage before deciding what to close") {
                Button("Activity Monitor") { openActivityMonitor() }
                Button("Refresh") { load() }
                Button("Done") { dismiss() }.carePrimaryAction()
            }

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
        .careScreen()
        .onAppear { load() }
        .confirmationDialog(
            "Quit \(confirmQuit?.command ?? "process")?",
            isPresented: Binding(
                get: { confirmQuit != nil },
                set: {
                    if !$0 {
                        confirmQuit = nil
                    }
                }
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
              let app = NSRunningApplication(processIdentifier: pid_t(row.pid))
        else {
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
    var valueColor: Color = CareTheme.ink
    var caption: String?
    /// Recent readings (0…100), oldest first, drawn as a small trend line.
    var trend: [Double] = []
    var actionLabel: String?
    var action: (() -> Void)?
    var secondaryActionLabel: String?
    var secondaryAction: (() -> Void)?
    var isBusy = false

    /// Two lines: title with its actions, then the reading with its trend.
    /// The caption, when there is one, sits under the reading in small type.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(CareTheme.secondaryInk)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(CareTheme.secondaryInk)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    if let actionLabel, let action {
                        Button(actionLabel, action: action)
                            .disabled(isBusy)
                            .accessibilityLabel("\(title): \(actionLabel)")
                    }
                    if let secondaryActionLabel, let secondaryAction {
                        Button(secondaryActionLabel, action: secondaryAction)
                            .accessibilityLabel("\(title): \(secondaryActionLabel)")
                    }
                }
                .font(.caption.bold())
                .buttonStyle(.plain)
                .foregroundStyle(CareTheme.accent)
            }
            HStack(alignment: .center, spacing: 8) {
                Text(value)
                    .font(.subheadline.bold())
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel("\(title): \(value)\(caption.map { ", \($0)" } ?? "")")
                if trend.count > 2 {
                    Chart(Array(trend.enumerated()), id: \.offset) { point in
                        LineMark(x: .value("Sample", point.offset), y: .value("Percent", point.element))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(CareTheme.accent)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 0 ... 100)
                    .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
                    .accessibilityLabel("\(title) over the last few minutes")
                    .accessibilityValue("Lowest \(Int(trend.min() ?? 0)) percent, highest \(Int(trend.max() ?? 0)) percent")
                } else {
                    Spacer(minLength: 0)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(CareTheme.secondaryInk)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
        .background(CareTheme.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CareTheme.border, lineWidth: 1))
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
        .cardSurface(radius: 15)
    }
}
