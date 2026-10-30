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
    @State private var showingCoverage = false
    @State private var hasFullDiskAccess = FullDiskAccessCheck.probe()
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
        // Sized to fit the window (its minimum is 860 × 600) without
        // scrolling: shorter windows get tighter spacing and a smaller hero.
        GeometryReader { geometry in
            let compact = geometry.size.width < 630
            let short = geometry.size.height < 700
            VStack(alignment: .leading, spacing: short ? 12 : 18) {
                HStack {
                    Text("OVERVIEW").font(.caption2.weight(.bold)).tracking(1.8).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onShowActivity) { Label("Live activity", systemImage: "waveform.path.ecg") }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .accessibilityHint("Open CPU, memory, battery and network monitoring")
                }
                hero(compact: compact, short: short)
                tools
                if canCare {
                    systemCare
                }
                coverageNote
                Spacer(minLength: 0)
                storage
            }
            .padding(short ? 18 : 24)
            .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .background(CareTheme.background)
        .task { await refreshStorage() }
        .onChange(of: coordinator.lastScanAt) { _, _ in Task { await refreshStorage() } }
        .onChange(of: work.isBusy) { _, busy in
            if !busy {
                Task { await refreshStorage() }
            }
        }
    }

    /// One line when any area was only partly checked; the details open in a
    /// popover instead of growing the page.
    @ViewBuilder private var coverageNote: some View {
        let partial = ScanEverythingCoordinator.Area.allCases.compactMap { area in
            coordinator.coverage[area].flatMap { $0.isPartial ? (area, $0) : nil }
        }
        if !hasFullDiskAccess {
            HStack(spacing: 6) {
                Image(systemName: "lock.circle").foregroundStyle(.orange)
                Text("Full Disk Access is off, so other apps’ caches and leftovers can’t be seen").font(.caption)
                Button("Grant…") { FullDiskAccessCheck.openSystemSettings() }
                    .controlSize(.small)
            }
        }
        if !partial.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text("Some locations couldn’t be checked").font(.caption)
                Button("Details") { showingCoverage = true }
                    .controlSize(.small)
                    .popover(isPresented: $showingCoverage) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(partial, id: \.0) { area, report in
                                    Text(Self.areaName(area)).font(.subheadline.weight(.semibold))
                                    ScanCoverageView(report)
                                }
                            }.padding()
                        }.frame(width: 420, height: 320)
                    }
            }
        }
    }

    private static func areaName(_ area: ScanEverythingCoordinator.Area) -> String {
        switch area {
        case .clean: String(localized: "Cleanup")
        case .apps: String(localized: "Applications")
        case .files: String(localized: "My files")
        case .startup: String(localized: "Startup items")
        case .storage: String(localized: "Storage")
        case .maintenance: String(localized: "System care")
        case .developer: String(localized: "Project Purge")
        }
    }

    private func hero(compact: Bool, short: Bool) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: short ? 8 : 11) {
                Text(headline)
                    .font(.system(size: short ? 26 : 32, weight: .bold, design: .rounded))
                    .tracking(-1).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if coordinator.isScanning {
                    ScanProgressBar(
                        coordinator.phase?.label ?? "Starting scan…",
                        detail: coordinator.progressDetail,
                        fraction: coordinator.progress,
                        onCancel: coordinator.cancelScan
                    )
                } else {
                    Text(coordinator.hasResults
                        ? "Nothing is removed until you review it."
                        : "Clear the clutter. Find your space. Give your Mac a little breathing room.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360, alignment: .leading)
                    HStack(spacing: 10) {
                        Button {
                            if let destination = reviewDestination {
                                open(destination)
                            } else {
                                Task { await coordinator.scanEverything(mode: scanMode) }
                            }
                        } label: {
                            Label(primaryTitle, systemImage: reviewDestination == nil ? "viewfinder" : "arrow.right")
                        }
                        // The shared style keeps its colour when the window is
                        // inactive; .borderedProminent turns white, hiding the text.
                        .carePrimaryAction().disabled(work.isBusy)
                        if reviewDestination != nil {
                            Button("Scan again") { Task { await coordinator.scanEverything(mode: scanMode) } }
                                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(CareTheme.accent)
                                .disabled(work.isBusy)
                        }
                        Picker("Scan mode", selection: $scanMode) {
                            Text("Quick").tag(ScanEverythingCoordinator.ScanMode.quick)
                            Text("Full").tag(ScanEverythingCoordinator.ScanMode.full)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().disabled(work.isBusy)
                        .help(scanMode.summary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                CareMacIllustration().scaleEffect(short ? 0.68 : 0.8)
                    .frame(width: short ? 150 : 180, height: short ? 140 : 170).accessibilityHidden(true)
            }
        }
        .padding(short ? 18 : 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [CareTheme.lilac, CareTheme.pink], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    /// Says what the scan found, not a slogan.
    private var headline: String {
        guard coordinator.hasResults else { return "A little care.\nA lighter Mac." }
        switch reviewDestination {
        case .clean: return "\(ByteSizeFormatter.format(cleanBytes))\nready to review."
        case nil: return "Nothing needs\nyour attention."
        default: return "Your results\nare ready."
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text(coordinator.hasResults ? "Your scan, at a glance" : "Care for every corner").font(.headline)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 10), count: max(
                    1,
                    [canClean, canApps, canFiles].filter { $0 }.count
                )),
                spacing: 10
            ) {
                // Fixed titles; the scan's figures go in the line beneath, so
                // nothing is cut off at the narrowest window.
                if canClean {
                    tool(
                        .clean,
                        title: "Clean up",
                        detail: coordinator.cleanPlans == nil
                            ? "Clear everyday clutter"
                            : "\(ByteSizeFormatter.format(cleanBytes)) of caches, logs & Trash",
                        icon: "paintbrush.pointed",
                        tint: CareTheme.accent
                    )
                }
                if canApps {
                    tool(
                        .uninstall,
                        title: "Applications",
                        detail: coordinator.apps.map {
                            "\($0.count) apps · \(ByteSizeFormatter.format(coordinator.appFootprintBytes))"
                        } ?? "Remove apps and leftovers",
                        icon: "square.grid.2x2",
                        tint: CareTheme.teal
                    )
                }
                if canFiles {
                    let large = coordinator.largeFiles.map { "\($0.count) large files" }
                    tool(
                        .duplicates,
                        title: "My files",
                        detail: duplicateBytes > 0
                            ? ["\(ByteSizeFormatter.format(duplicateBytes)) in duplicates", large]
                            .compactMap { $0 }.joined(separator: " · ")
                            : large.map { "\($0) to explore" } ?? "Find space to breathe",
                        icon: "folder",
                        tint: CareTheme.blue
                    )
                }
            }
            // The one place scan times are shown: each area keeps its own,
            // since a screen can be rescanned on its own.
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
                        .frame(width: 32, height: 32).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(CareTheme.accent)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14).background(CareTheme.panel, in: RoundedRectangle(cornerRadius: 15))
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
        .padding(12).background(CareTheme.panel, in: RoundedRectangle(cornerRadius: 13))
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
        volume = await Task.detached { DiskScanner.startupVolumeInfo() }.value
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
