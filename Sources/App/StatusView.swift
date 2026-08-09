import SwiftUI
import Core
import Features
import UI

struct StatusView: View {
    @State private var snapshot: MetricsSnapshot?
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("System Status").font(.title2).bold()
                Spacer()
            }
            .padding([.horizontal, .top])

            if let snap = snapshot {
                ScrollView {
                    VStack(spacing: 12) {
                        // Health score banner
                        HealthBanner(snapshot: snap)

                        StatCard(title: "CPU") {
                            MetricRow(label: "Usage", percent: snap.cpu.usage, color: .blue)
                            if !snap.cpu.perCore.isEmpty {
                                Text("\(snap.cpu.logicalCPU) logical cores")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        StatCard(title: "Memory") {
                            MetricRow(label: "Used", percent: snap.memory.usedPercent,
                                      color: SizeBar.color(for: snap.memory.usedPercent))
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
                    }
                    .padding()
                }
            } else {
                ProgressView("Collecting metrics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
}

private struct HealthBanner: View {
    let snapshot: MetricsSnapshot

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading) {
                Text("Health \(snapshot.healthScore)")
                    .font(.title3.bold())
                Text(snapshot.healthScoreMsg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(snapshot.host)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch snapshot.healthScore {
        case 85...: .green
        case 65..<85: .yellow
        case 45..<65: .orange
        default: .red
        }
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