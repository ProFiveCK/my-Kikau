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
    // Marks that this user actually uses Analyse, so the launch-time
    // background preload (see myKikauApp) knows it's worth doing for them.
    @AppStorage(AppStorageKey.hasUsedAnalyze) private var hasUsedAnalyze = false
    // Non-empty means Desktop/Documents/Downloads under-report or read as
    // empty here without any visible error — see ProtectedFolderAccessCheck.
    @State private var deniedFolders: [String] = ProtectedFolderAccessCheck.deniedFolders()

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
                if !session.isOverview && !session.entries.isEmpty {
                    Menu {
                        Toggle("Show hidden items", isOn: $session.showHidden)
                    } label: {
                        Image(systemName: session.showHidden ? "eye" : "eye.slash")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Show or hide dot-prefixed items like .cache, .npm, .docker")
                }
                if session.canNavigateUp {
                    Button {
                        session.navigateUp()
                    } label: {
                        Label("Up", systemImage: "arrow.up")
                    }
                }
                Button(scanButtonTitle) {
                    deniedFolders = ProtectedFolderAccessCheck.deniedFolders()
                    if session.hasResults {
                        session.rescanCurrent()
                    } else {
                        session.scanVolumeOverview()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(session.isScanning)
            }
            .padding()

            if !deniedFolders.isEmpty {
                ProtectedFolderAccessBanner(deniedFolders: deniedFolders)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if !session.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    BreadcrumbBar(
                        volumeName: session.volumeName,
                        currentDir: session.currentDir,
                        onSelectRoot: { session.scanVolumeOverview() },
                        onSelect: { session.scan($0) }
                    )
                    if let lastScanAt = session.lastScanAt {
                        Text("Last scanned \(lastScanAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if session.entries.isEmpty && !session.isScanning {
                ContentUnavailableView {
                    Label("No Scan Yet", systemImage: "chart.pie")
                } description: {
                    Text("Analyse the whole startup disk — see used vs free space, then drill into the folders using the most storage.")
                } actions: {
                    Button("Analyse Disk") { session.scanVolumeOverview() }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                }
            } else if session.isScanning && session.entries.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Measuring disk usage…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mode == .chart {
                PieChartSection(
                    entries: session.entries,
                    centerCaption: session.isOverview ? "of \(session.volumeName)" : "total"
                ) { entry in
                    if entry.isNavigable {
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
                        color: { entry, rank in mapCellColor(for: entry, rank: rank, total: mapEntries.count) },
                        label: { $0.name },
                        sublabel: { ByteSizeFormatter.format($0.sizeBytes) },
                        onSelect: { entry in
                            if entry.isNavigable { session.scan(entry.url) }
                        }
                    )
                    .frame(minWidth: 360)

                    List(mapEntries) { entry in
                        AnalyzeRow(entry: entry, tint: tint, maxSize: mapEntries.map(\.sizeBytes).max() ?? 1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if entry.isNavigable { session.scan(entry.url) }
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
                            if entry.isNavigable { session.scan(entry.url) }
                        }
                }
            }
        }
        .onAppear {
            hasUsedAnalyze = true
            if session.entries.isEmpty {
                session.adoptCacheIfAvailable()
            }
        }
    }

    private var scanButtonTitle: String {
        if session.isScanning { return "Scanning..." }
        return session.hasResults ? "Rescan" : "Analyse Disk"
    }

    /// Darker teal for the biggest items, easing lighter toward the smallest —
    /// capped so even the lightest cell stays dark enough for white labels.
    /// Synthetic rows (Free, "macOS System") get a neutral grey instead so
    /// they read as "not a folder you can open".
    private func mapCellColor(for entry: DiskScanner.Entry, rank: Int, total: Int) -> Color {
        if !entry.isNavigable {
            return entry.name == "Free"
                ? Color(hue: 0.33, saturation: 0.18, brightness: 0.45)
                : Color(white: 0.38)
        }
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

/// Finder-style path bar: a tappable chain from the disk root down to the
/// folder currently shown. Replaces the old single "Back" button — you can
/// jump up any number of levels in one click, and the current position is
/// always visible.
private struct BreadcrumbBar: View {
    let volumeName: String
    let currentDir: URL?
    let onSelectRoot: () -> Void
    let onSelect: (URL) -> Void

    private struct Crumb: Identifiable {
        let id: Int
        let name: String
        let url: URL?   // nil == the disk-overview root
    }

    private var crumbs: [Crumb] {
        var result: [Crumb] = [Crumb(id: 0, name: volumeName, url: nil)]
        guard let currentDir else { return result }
        let parts = currentDir.pathComponents.filter { $0 != "/" }
        var accumulated = URL(fileURLWithPath: "/")
        for (index, part) in parts.enumerated() {
            accumulated.appendPathComponent(part)
            result.append(Crumb(id: index + 1, name: part, url: accumulated))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    let isLast = index == crumbs.count - 1
                    Button {
                        if let url = crumb.url { onSelect(url) } else { onSelectRoot() }
                    } label: {
                        HStack(spacing: 3) {
                            if index == 0 {
                                Image(systemName: "internaldrive").font(.caption2)
                            }
                            Text(crumb.name)
                                .font(.caption)
                                .fontWeight(isLast ? .semibold : .regular)
                        }
                        .foregroundStyle(isLast ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)

                    if !isLast {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
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
    var centerCaption: String = "total"
    let onSelect: (DiskScanner.Entry) -> Void

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let sizeBytes: Int64
        let color: Color
        let entry: DiskScanner.Entry?   // nil for the aggregated "Other" slice
        var isNavigable: Bool { entry?.isNavigable == true }
    }

    private static let palette: [Color] = [
        .teal, .blue, .purple, .pink, .orange, .yellow, .green, .indigo, .mint, .cyan,
    ]

    /// Neutral greys for the computed rows so they don't compete with the
    /// folder palette — Free is the lightest, System a mid grey.
    private static func neutralColor(for name: String) -> Color {
        switch name {
        case "Free": return Color(white: 0.82)
        case "macOS System": return Color(white: 0.55)
        default: return Color(white: 0.68)   // "Hidden Items" and any other aggregate
        }
    }

    private var slices: [Slice] {
        // Real folders take the colour palette and the top-N treatment; the
        // smaller ones roll up into "Other". Computed rows (Free, macOS System,
        // Hidden Items) always keep their own slice — never folded into "Other"
        // — so the donut visibly sums to the whole disk.
        let navigable = entries.filter { $0.isNavigable }
        let computed = entries.filter { !$0.isNavigable }

        let topCount = 9
        var result: [Slice] = []
        for (index, entry) in navigable.prefix(topCount).enumerated() {
            result.append(Slice(
                id: entry.id,
                name: entry.name,
                sizeBytes: entry.sizeBytes,
                color: Self.palette[index % Self.palette.count],
                entry: entry
            ))
        }
        if navigable.count > topCount {
            let rest = navigable.dropFirst(topCount)
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
        for entry in computed {
            result.append(Slice(
                id: entry.id,
                name: entry.name,
                sizeBytes: entry.sizeBytes,
                color: Self.neutralColor(for: entry.name),
                entry: entry
            ))
        }
        // Order every slice by size so the legend matches List/Map — except
        // "Free", which is pinned last so the donut reads used-space first,
        // then the gap.
        return result.sorted { lhs, rhs in
            if lhs.name == "Free" { return false }
            if rhs.name == "Free" { return true }
            return lhs.sizeBytes > rhs.sizeBytes
        }
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
                    Text(centerCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(slices) { slice in
                        Button {
                            if let entry = slice.entry, entry.isNavigable { onSelect(entry) }
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
                                if slice.isNavigable {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(!slice.isNavigable)
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

    private var icon: String {
        if !entry.isNavigable {
            return entry.name == "Free" ? "circle.dashed" : "gearshape.2"
        }
        return entry.isDirectory ? "folder.fill" : "doc.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.isNavigable ? tint : .secondary)
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
                SizeBar(percent: relativeSize, color: entry.isNavigable ? tint : .gray)
                if entry.isDirectory {
                    Text("\(entry.childCount) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if entry.isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
