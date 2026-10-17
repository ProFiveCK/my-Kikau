import AppKit
import SwiftUI
import Core
import Features
import UI

/// Action-first overview. Every value comes from the same results the destination
/// screen reviews; no demo values, synthetic health score or implied cleanup.
struct CareHubView: View {
    let onNavigate: (ContentView.SidebarItem) -> Void
    let onShowActivity: () -> Void
    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var work = WorkCoordinator.shared
    @AppStorage(AppStorageKey.careScanMode) private var scanMode: ScanEverythingCoordinator.ScanMode = .quick
    @State private var volume: DiskScanner.VolumeInfo?
    @State private var totals = OperationLog.Totals()
    private var cleanBytes: Int64 {
        coordinator.cleanPlans?.values.reduce(0) { $0 + $1.totalReclaimable } ?? 0
    }

    private var duplicateBytes: Int64 {
        coordinator.duplicateGroups?.reduce(0) { $0 + $1.reclaimableBytes } ?? 0
    }

    private var canClean: Bool {
        !ManagedPolicy.shared.isFeatureDisabled("clean")
    }

    private var canApps: Bool {
        !ManagedPolicy.shared.isFeatureDisabled("uninstall")
    }

    private var canFiles: Bool {
        !ManagedPolicy.shared.isFeatureDisabled("duplicates")
    }

    private var canCare: Bool {
        !ManagedPolicy.shared.isFeatureDisabled("optimize")
    }

    private var reviewDestination: ContentView.SidebarItem? {
        if canClean, cleanBytes > 0 {
            return .clean
        }
        if canFiles, duplicateBytes > 0 || !(coordinator.largeFiles ?? []).isEmpty {
            return .duplicates
        }
        if canCare, coordinator.maintenanceIssueCount > 0 {
            return .optimize
        }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("OVERVIEW").font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: onShowActivity) { Label("Live activity", systemImage: "waveform.path.ecg") }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                            .accessibilityHint("Open CPU, memory, battery and network monitoring")
                    }
                    hero(compact: geometry.size.width < 630)
                    if coordinator.isScanning {
                        ScanProgressBar(
                            coordinator.phase?.label ?? "Starting scan…",
                            detail: coordinator.progressDetail,
                            fraction: coordinator.progress,
                            onCancel: coordinator.cancelScan
                        )
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Scan mode", selection: $scanMode) {
                            ForEach(ScanEverythingCoordinator.ScanMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }.pickerStyle(.segmented).frame(maxWidth: 320).disabled(work.isBusy)
                        Text(scanMode.summary).font(.caption).foregroundStyle(.secondary)
                        if let mode = coordinator.lastScanMode, let date = coordinator.lastScanAt {
                            Text(
                                "\(mode.title) completed \(date.formatted(date: .abbreviated, time: .shortened)). Each area shows when it was checked."
                            )
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    tools
                    if canCare {
                        systemCare
                    }
                    if !coordinator.coverage.isEmpty {
                        let partial = coordinator.coverage.filter(\.value.isPartial)
                        if !partial.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Some locations couldn’t be checked").font(.subheadline.weight(.semibold))
                                ForEach(ScanEverythingCoordinator.Area.allCases.filter { partial[$0] != nil }, id: \.self) { area in
                                    if let report = partial[area] {
                                        ScanCoverageView(report)
                                    }
                                }
                            }
                        }
                    }
                    storage
                    if totals.trashedBytes > 0 || totals.freedBytes > 0 {
                        let moved = ByteSizeFormatter.format(totals.trashedBytes)
                        let removed = ByteSizeFormatter.format(totals.freedBytes)
                        Text("Activity totals · \(moved) moved to Trash · \(removed) permanently removed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(26)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(CareTheme.background)
        }
        .task { await refreshStorage() }
        .onChange(of: coordinator.lastScanAt) { _, _ in Task { await refreshStorage() } }
        .onChange(of: work.isBusy) { _, busy in
            if !busy {
                Task { await refreshStorage() }
            }
        }
    }

    private func hero(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 22) {
            VStack(alignment: .leading, spacing: 13) {
                Text(coordinator
                    .hasResults ?
                    (reviewDestination == nil ? "Your scan is ready.\nYou’re in control." : "A little clutter.\nA lot of possibility.") :
                    "A little care.\nA lighter Mac.")
                    .font(.system(size: compact ? 29 : 36, weight: .bold, design: .rounded))
                    .tracking(-1.1).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(coordinator.hasResults
                    ? "Your results are ready. Choose what to review, and keep everything you need."
                    : "Clear the clutter. Find your space. Give your Mac a little breathing room.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 310, alignment: .leading)
                HStack(spacing: 9) {
                    Button {
                        if let destination = reviewDestination {
                            open(destination)
                        } else {
                            Task { await coordinator.scanEverything(mode: scanMode) }
                        }
                    } label: {
                        Label(primaryTitle, systemImage: reviewDestination == nil ? "viewfinder" : "arrow.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(CareTheme.onAccent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).tint(CareTheme.accent).disabled(work.isBusy)
                    if reviewDestination != nil {
                        Button(scanMode.title) { Task { await coordinator.scanEverything(mode: scanMode) } }
                            .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(CareTheme.accent).disabled(work.isBusy)
                    }
                }.padding(.top, 4)
                Label(
                    coordinator.hasResults ? "Review first. You’re in control." : "On your Mac. In your control.",
                    systemImage: coordinator.hasResults ? "checkmark" : "lock"
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CareMacIllustration().frame(width: compact ? 160 : 222, height: 208).accessibilityHidden(true)
        }
        .padding(compact ? 23 : 29)
        .frame(maxWidth: .infinity, minHeight: 258, alignment: .leading)
        .background(
            LinearGradient(colors: [CareTheme.lilac, CareTheme.pink], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22)
        )
    }

    private var primaryTitle: String {
        if coordinator.isScanning {
            return "Scanning…"
        }
        switch reviewDestination {
        case .clean: return "Review \(ByteSizeFormatter.format(cleanBytes))"
        case .duplicates: return "Review files"
        case .optimize: return "Review system care"
        default: return scanMode.title
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(coordinator.hasResults ? "Your scan, at a glance" : "Care for every corner").font(.headline)
                Spacer()
                if let date = coordinator.lastScanAt {
                    Text("\(coordinator.lastScanMode?.title ?? "Scan") · \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 12), count: max(
                    1,
                    [canClean, canApps, canFiles].filter { $0 }.count
                )),
                spacing: 12
            ) {
                if canClean {
                    tool(
                        .clean,
                        title: coordinator.cleanPlans == nil ? "Clean up" : ByteSizeFormatter.format(cleanBytes) + " to review",
                        detail: coordinator.cleanPlans == nil ? "Clear everyday clutter" : "Caches, logs & Trash contents",
                        icon: "paintbrush.pointed",
                        tint: CareTheme.accent
                    )
                }
                if canApps {
                    tool(
                        .uninstall,
                        title: coordinator.apps.map { "\($0.count) applications" } ?? "Applications",
                        detail: coordinator.apps == nil ? "Remove apps and leftovers" : ByteSizeFormatter
                            .format(coordinator.appFootprintBytes) + " installed",
                        icon: "square.grid.2x2",
                        tint: CareTheme.teal
                    )
                }
                if canFiles {
                    tool(
                        .duplicates,
                        title: coordinator.duplicateGroups == nil ? "My files" : duplicateBytes > 0 ? ByteSizeFormatter
                            .format(duplicateBytes) + " in duplicates" : "Explore your files",
                        detail: coordinator.largeFiles.map { "\($0.count) large files to explore" } ?? "Find space to breathe",
                        icon: "folder",
                        tint: CareTheme.blue
                    )
                }
            }
            HStack {
                if canClean {
                    checkedDate(.clean, title: "Cleanup")
                }
                if canApps {
                    checkedDate(.apps, title: "Apps")
                }
                if canFiles {
                    checkedDate(.files, title: "Files")
                }
            }
        }
    }

    private func checkedDate(_ area: ScanEverythingCoordinator.Area, title: String) -> some View {
        Text(coordinator.scannedAt[area]
            .map { "\(title) · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "\(title) · Not checked")
            .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tool(_ destination: ContentView.SidebarItem, title: String, detail: String, icon: String, tint: Color) -> some View {
        Button { open(destination) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 21, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 41, height: 41).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label("Review", systemImage: "arrow.up.right").font(.caption.weight(.medium)).foregroundStyle(CareTheme.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 139, alignment: .topLeading)
            .padding(18).background(CareTheme.panel, in: RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain).accessibilityHint("Open \(destination.label) with the current scan results")
    }

    private var systemCare: some View {
        HStack(spacing: 11) {
            Image(systemName: "info.circle").foregroundStyle(CareTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                if coordinator.maintenanceResults == nil {
                    Text("System care").font(.subheadline.weight(.semibold))
                    Text("Maintenance checks and privacy information").font(.caption).foregroundStyle(.secondary)
                } else {
                    let incomplete = coordinator.maintenanceResults?.values.filter(\.outcome.isIncomplete).count ?? 0
                    let count = coordinator.maintenanceIssueCount
                    let recommendations = "\(count) maintenance recommendation\(count == 1 ? "" : "s")"
                    let suffix = incomplete > 0 ? " · \(incomplete) check\(incomplete == 1 ? "" : "s") incomplete" : ""
                    Text(recommendations + suffix)
                        .font(.subheadline.weight(.semibold))
                    let notes = coordinator.systemHealthReport?.informationalCount ?? 0
                    Text("\(notes) privacy note\(notes == 1 ? "" : "s") · information only")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Review") { onNavigate(.optimize) }.buttonStyle(.plain).font(.caption.weight(.semibold))
                .foregroundStyle(CareTheme.accent)
        }
        .padding(15).background(CareTheme.panel, in: RoundedRectangle(cornerRadius: 13))
    }

    @ViewBuilder private var storage: some View {
        if let volume {
            VStack(spacing: 9) {
                HStack {
                    Button { onNavigate(.analyze) } label: { Text(volume.name).fontWeight(.semibold) }
                        .buttonStyle(.plain).disabled(ManagedPolicy.shared.isFeatureDisabled("analyze"))
                    Text("· \(ByteSizeFormatter.format(volume.totalBytes))").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ByteSizeFormatter.format(volume.freeBytes)) available").foregroundStyle(.secondary)
                }.font(.caption)
                ProgressView(value: Double(max(0, volume.totalBytes - volume.freeBytes)), total: Double(max(1, volume.totalBytes)))
                    .tint(CareTheme.accent).accessibilityLabel("Startup disk storage used")
            }
        }
    }

    private func open(_ destination: ContentView.SidebarItem) {
        if destination == .duplicates {
            AppNavigation.shared.pendingDuplicatesMode = duplicateBytes > 0 ? .duplicates : .largeFiles
        }
        onNavigate(destination)
    }

    private func refreshStorage() async {
        let values = await Task.detached { (DiskScanner.startupVolumeInfo(), OperationLog.shared.totals()) }.value
        volume = values.0; totals = values.1
    }
}

private struct CareMacIllustration: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.025)).frame(width: 205)
            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1).frame(width: 163)
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .lightGray))
                    RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.24, green: 0.16, blue: 0.34)).padding(6)
                    ZStack {
                        LinearGradient(
                            colors: [Color(red: 0.49, green: 0.33, blue: 0.73), Color(red: 0.72, green: 0.54, blue: 0.84)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Ellipse().fill(Color(red: 0.92, green: 0.68, blue: 0.81)).frame(width: 210, height: 120).offset(x: -48, y: 62)
                        Ellipse().fill(Color(red: 0.48, green: 0.77, blue: 0.73)).frame(width: 215, height: 105)
                            .rotationEffect(.degrees(-20)).offset(
                                x: 65,
                                y: 64
                            )
                    }.clipShape(RoundedRectangle(cornerRadius: 3)).padding(11)
                }.frame(width: 176, height: 120)
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: .lightGray)).frame(width: 26, height: 24)
                Capsule().fill(Color(nsColor: .lightGray)).frame(width: 63, height: 5)
            }
            .rotationEffect(.degrees(-8)).shadow(color: .black.opacity(0.13), radius: 14, y: 15).offset(y: 10)
            Image(systemName: "paintbrush.pointed.fill").font(.system(size: 24)).foregroundStyle(.teal)
                .frame(width: 48, height: 48).background(Color.mint.opacity(0.7), in: RoundedRectangle(cornerRadius: 15))
                .rotationEffect(.degrees(-17)).offset(x: -83, y: -58)
            Image(systemName: "folder").font(.system(size: 22)).foregroundStyle(.orange)
                .frame(width: 43, height: 43).background(Color.yellow.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
                .rotationEffect(.degrees(14)).offset(x: 88, y: 50)
            Image(systemName: "sparkles").font(.system(size: 21)).foregroundStyle(.white.opacity(0.8)).offset(x: 72, y: -85)
        }
        .scaleEffect(0.91)
    }
}
