import SwiftUI
import Core
import Features
import UI

/// Menu bar HUD showing live system metrics.
struct HUDView: View {
    @State private var snapshot: MetricsSnapshot?
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snap = snapshot {
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

            Button("Open myKikau") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.title == "myKikau" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Button("Quit myKikau") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 240)
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private func startTimer() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        snapshot = await MetricsCollector.shared.collect()
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