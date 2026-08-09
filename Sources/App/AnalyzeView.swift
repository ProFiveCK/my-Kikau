import SwiftUI
import Charts
import Core
import Features
import UI

struct AnalyzeView: View {
    private enum ViewMode: String, CaseIterable, Identifiable {
        case chart = "Chart"
        case map = "Map"
        case list = "List"
        var id: String { rawValue }
    }

    @ObservedObject private var session = AnalyzeScanSession.shared
    @State private var mode: ViewMode = .chart

    private let tint = ContentView.SidebarItem.analyze.tint

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: ContentView.SidebarItem.analyze.icon)
                    .foregroundStyle(tint)
                Text("Disk Analyser").font(.title2).bold()
                Spacer()
                if !session.entries.isEmpty {
                    Picker("View", selection: $mode) {
                        ForEach(ViewMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                if let dir = session.currentDir {
                    Button("Back") {
                        session.scan(dir.deletingLastPathComponent())
                    }
                }
                Button(session.isScanning ? "Scanning..." : (session.hasResults ? "Rescan" : "Scan Home")) {
                    if session.hasResults {
                        session.rescanCurrent()
                    } else {
                        session.scan(FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(session.isScanning)
            }
            .padding()

            if let dir = session.currentDir, !session.entries.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dir.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let lastScanAt = session.lastScanAt {
                        Text("Last scanned \(lastScanAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if session.entries.isEmpty && !session.isScanning {
                ContentUnavailableView(
                    "No Scan Yet",
                    systemImage: "chart.bar.doc.horizontal",
                    description: Text("Click Scan Home to analyse allocated disk usage and find large files.")
                )
            } else if mode == .chart {
                PieChartSection(entries: session.entries) { entry in
                    if entry.isDirectory {
                        session.scan(entry.url)
                    }
                }
                .padding([.horizontal, .bottom])
            } else if mode == .map {
                let mapEntries = condensedMapEntries(session.entries)
                HSplitView {
                    TreemapView(
                        items: mapEntries,
                        value: { Double($0.sizeBytes) },
                        color: { _, rank in cellColor(rank: rank, total: mapEntries.count) },
                        label: { $0.name },
                        sublabel: { ByteSizeFormatter.format($0.sizeBytes) },
                        onSelect: { entry in
                            if entry.isDirectory, entry.id != "__smaller_items" {
                                session.scan(entry.url)
                            }
                        }
                    )
                    .frame(minWidth: 360)

                    List(mapEntries) { entry in
                        AnalyzeRow(entry: entry, tint: tint, maxSize: mapEntries.map(\.sizeBytes).max() ?? 1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if entry.isDirectory, entry.id != "__smaller_items" {
                                    session.scan(entry.url)
                                }
                            }
                    }
                    .frame(minWidth: 260, idealWidth: 320)
                }
                .padding([.horizontal, .bottom])
            } else {
                let maxSize = session.entries.map(\.sizeBytes).max() ?? 1
                List(session.entries) { entry in
                    AnalyzeRow(entry: entry, tint: tint, maxSize: maxSize)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if entry.isDirectory {
                                session.scan(entry.url)
                            }
                        }
                }
            }
        }
    }

    /// Darker teal for the biggest items, easing lighter toward the smallest —
    /// capped so even the lightest cell stays dark enough for white labels.
    /// The old version only spanned a narrow brightness/saturation band, so a
    /// screen full of cells read as a near-flat wash of one color with no way
    /// to tell items apart except by size. Widened range plus a slight hue
    /// drift gives adjacent cells more visual separation at a glance.
    private func cellColor(rank: Int, total: Int) -> Color {
        let t = total > 1 ? Double(rank) / Double(total - 1) : 0
        let eased = min(t, 1)
        let hue = 0.5 + eased * 0.06
        return Color(hue: hue, saturation: 0.75 - eased * 0.25, brightness: 0.30 + eased * 0.32)
    }

    private func condensedMapEntries(_ entries: [DiskScanner.Entry]) -> [DiskScanner.Entry] {
        let visibleCount = 24
        guard entries.count > visibleCount else { return entries }
        let visible = Array(entries.prefix(visibleCount))
        let rest = entries.dropFirst(visibleCount)
        let restTotal = rest.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard restTotal > 0 else { return visible }
        let aggregate = DiskScanner.Entry(
            url: URL(fileURLWithPath: "/Smaller Items"),
            sizeBytes: restTotal,
            isDirectory: false,
            childCount: rest.count
        )
        return visible + [aggregate]
    }
}

/// Donut chart + tappable legend — the default Analyse view. Uses Swift
/// Charts' `SectorMark` (macOS 14+) rather than hand-rolled arc drawing, so
/// slice geometry and the color-per-category palette are handled by a
/// proven framework instead of custom math. Drill-down happens via the
/// legend rows (reliable button taps) rather than hit-testing chart
/// gestures, which keeps the interaction identical to Map/List.
private struct PieChartSection: View {
    let entries: [DiskScanner.Entry]
    let onSelect: (DiskScanner.Entry) -> Void

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let sizeBytes: Int64
        let color: Color
        let entry: DiskScanner.Entry?   // nil for the aggregated "Other" slice
    }

    private static let palette: [Color] = [
        .teal, .blue, .purple, .pink, .orange, .yellow, .green, .indigo, .mint, .cyan,
    ]

    private var slices: [Slice] {
        let topCount = 9
        var result: [Slice] = []
        for (index, entry) in entries.prefix(topCount).enumerated() {
            result.append(Slice(
                id: entry.id,
                name: entry.name,
                sizeBytes: entry.sizeBytes,
                color: Self.palette[index % Self.palette.count],
                entry: entry
            ))
        }
        if entries.count > topCount {
            let rest = entries.dropFirst(topCount)
            let otherTotal = rest.reduce(Int64(0)) { $0 + $1.sizeBytes }
            if otherTotal > 0 {
                result.append(Slice(
                    id: "__other",
                    name: "Other (\(rest.count) items)",
                    sizeBytes: otherTotal,
                    color: .gray,
                    entry: nil
                ))
            }
        }
        return result
    }

    private var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            ZStack {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Size", slice.sizeBytes),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(4)
                }
                .chartLegend(.hidden)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 320, minHeight: 240, idealHeight: 280, maxHeight: 320)

                VStack(spacing: 2) {
                    Text(ByteSizeFormatter.format(totalBytes))
                        .font(.title3.bold())
                    Text("total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(slices) { slice in
                        Button {
                            if let entry = slice.entry { onSelect(entry) }
                        } label: {
                            HStack(spacing: 10) {
                                Circle().fill(slice.color).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(slice.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(ByteSizeFormatter.format(slice.sizeBytes))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(percentString(slice.sizeBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if slice.entry?.isDirectory == true {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(slice.entry == nil)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func percentString(_ bytes: Int64) -> String {
        guard totalBytes > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(bytes) / Double(totalBytes) * 100)
    }
}

private struct AnalyzeRow: View {
    let entry: DiskScanner.Entry
    let tint: Color
    let maxSize: Int64

    private var relativeSize: Double {
        maxSize > 0 ? Double(entry.sizeBytes) / Double(maxSize) * 100 : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name)
                    Spacer()
                    Text(ByteSizeFormatter.format(entry.sizeBytes))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SizeBar(percent: relativeSize, color: tint)
                if entry.isDirectory {
                    Text("\(entry.childCount) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
