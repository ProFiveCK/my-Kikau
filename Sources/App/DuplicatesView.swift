import SwiftUI
import Core
import Features
import UI

/// Finds duplicate files (true content matches) and separately surfaces
/// large files, across Downloads/Documents/Desktop/Pictures/Movies and any
/// folders added in Settings — the "My Clutter" equivalent, scoped to the
/// user's own content rather than app/system data (that's what Clean and
/// Purge already own).
struct DuplicatesView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case duplicates = "Duplicates"
        case largeFiles = "Large Files"
        case similar = "Similar Photos"
        var id: String {
            rawValue
        }
    }

    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var model = FilesModel.shared
    @State private var mode: Mode = .duplicates
    private var selectedLargeFiles: Set<String> {
        get { model.selectedLargeFiles }
        nonmutating set { model.selectedLargeFiles = newValue }
    }

    @State private var review: ReviewRequest?
    @State private var staleNotice = false
    private var selectedSimilar: Set<String> {
        get { model.selectedSimilar }
        nonmutating set { model.selectedSimilar = newValue }
    }

    /// Non-empty means macOS hasn't granted access to one of the folders this
    /// feature scans — the most likely explanation for "Duplicates always
    /// finds nothing" on a Mac that obviously has files there (see
    /// ProtectedFolderAccessCheck).
    @State private var deniedFolders: [String] = ProtectedFolderAccessCheck.deniedFolders()

    @ObservedObject private var activity = WorkCoordinator.shared

    private let tint = ContentView.SidebarItem.duplicates.tint

    private var duplicateGroups: [DuplicateFinder.DuplicateGroup] {
        coordinator.duplicateGroups ?? []
    }

    private var largeFiles: [DuplicateFinder.FileEntry] {
        coordinator.largeFiles ?? []
    }

    private var hasScanned: Bool {
        coordinator.duplicateGroups != nil || coordinator.largeFiles != nil
    }

    private var totalDuplicateReclaimable: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private var subtitle: String {
        if model.isScanning {
            return "Scanning…"
        }
        if mode == .similar {
            guard let report = model.similar else { return "Pictures that look alike without being exact copies" }
            return report.groups.isEmpty
                ? "No similar pictures among \(report.imagesExamined.formatted()) examined"
                : "\(report.groups.count) set\(report.groups.count == 1 ? "" : "s") of similar pictures"
        }
        guard hasScanned else { return "Your own folders — never app or system data" }
        switch mode {
        case .duplicates:
            return duplicateGroups.isEmpty
                ?
                (coordinator.coverage[.files]?
                    .isPartial == true ? "No duplicates in the files checked · partial scan" : "No duplicates found")
                : "\(duplicateGroups.count) set\(duplicateGroups.count == 1 ? "" : "s") of duplicates · \(ByteSizeFormatter.format(totalDuplicateReclaimable)) reclaimable"
        case .largeFiles:
            let threshold = ByteSizeFormatter.formatRounded(DuplicateFinder.largeFileThreshold)
            return largeFiles.isEmpty ? "Nothing over \(threshold)" : "\(largeFiles.count) files over \(threshold)"
        case .similar:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("My files", subtitle: subtitle, systemImage: ContentView.SidebarItem.duplicates.icon, tint: tint) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(LocalizedStringKey(m.rawValue)).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                Button(mode == .similar ? (model.similar == nil ? "Find" : "Find Again") : (hasScanned ? "Rescan" : "Scan")) {
                    deniedFolders = ProtectedFolderAccessCheck.deniedFolders()
                    selectedLargeFiles = []
                    if mode == .similar {
                        selectedSimilar = []
                        model.findSimilar()
                    } else {
                        model.scan()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .carePrimaryAction()
                .tint(tint)
                .disabled(activity.isBusy)
            }

            if hasScanned, mode != .similar {
                CareSummary([("Duplicate sets", duplicateGroups.count.formatted()),
                             ("Duplicate space", ByteSizeFormatter.format(totalDuplicateReclaimable)),
                             ("Large files", largeFiles.count.formatted())])
            }
            if !deniedFolders.isEmpty {
                ProtectedFolderAccessBanner(deniedFolders: deniedFolders)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if model.isScanning {
                ScanProgressBar(
                    model.progressTitle,
                    detail: model.progressDetail,
                    fraction: model.progressFraction,
                    onCancel: model.cancel
                )
                .padding([.horizontal, .bottom])
            }

            if let coverage = mode == .similar ? model.similarCoverage : coordinator
                .coverage[.files]
            {
                ScanCoverageView(coverage).padding(.horizontal).padding(
                    .bottom,
                    8
                )
            }
            if mode == .similar {
                similarList
            } else if !hasScanned {
                if model.isScanning {
                    Spacer()
                } else {
                    CareEmptyState("Find your space to breathe.", systemImage: "doc.on.doc", description: Text(
                        "Find exact duplicates and large files in your own folders. Similar-photo comparison runs only when you choose it."
                    )) {
                        Button("Scan Files") { model.scan() }.carePrimaryAction().disabled(activity.isBusy)
                    }
                }
            } else if mode == .duplicates {
                duplicatesList
            } else if mode == .largeFiles {
                largeFilesList
            }

            if hasScanned, coordinator.skippedCloudOnlyFiles > 0 {
                Label(
                    "\(coordinator.skippedCloudOnlyFiles.formatted()) file(s) stored only in iCloud were skipped — checking them would download them.",
                    systemImage: "icloud"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
        .careScreen()
        .sheet(item: $review) { request in
            PlanReviewView(
                plan: request.plan,
                title: request.title,
                subtitle: request.subtitle,
                action: request.action
            ) { result in
                if let result, !result.dryRun {
                    coordinator.removeDuplicateFiles(ids: result.removedIDs)
                    model.removeSimilarFiles(ids: result.removedIDs)
                    selectedSimilar.subtract(result.removedIDs)
                    selectedLargeFiles.subtract(result.removedIDs)
                    if !result.removedIDs.isEmpty {
                        AnalyzeScanSession.shared.markStale()
                    }
                }
                review = nil
            }
        }
        .alert("These Files Have Changed", isPresented: $staleNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "The files were moved, removed or edited after the scan, so nothing was queued for removal. Scan again for an up-to-date list."
            )
        }
        .onAppear {
            if let pendingMode = AppNavigation.shared.pendingDuplicatesMode {
                mode = pendingMode == .largeFiles ? .largeFiles : .duplicates
                AppNavigation.shared.pendingDuplicatesMode = nil
            }
        }
    }

    @ViewBuilder
    private var duplicatesList: some View {
        if duplicateGroups.isEmpty {
            CareEmptyState(
                "No Duplicates Found",
                systemImage: "checkmark.circle",
                description: Text("Nothing duplicated across your scanned folders.")
            )
        } else {
            List {
                Section {
                    HStack {
                        Text("The starred copy in each set is kept. Click another copy to keep that one instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Review All…") {
                            openDuplicateReview(
                                duplicateGroups,
                                subtitle: "One copy of each file is kept. Untick anything else you want to keep."
                            )
                        }
                        .carePrimaryAction()
                        .tint(tint)
                    }
                }
                ForEach(duplicateGroups) { group in
                    Section("\(group.files.count) copies · \(ByteSizeFormatter.format(group.sizeBytes)) each") {
                        ForEach(group.files) { file in
                            DuplicateFileRow(
                                file: file,
                                isKeeper: file.id == group.keeper?.id,
                                tint: tint
                            ) {
                                coordinator.setKeeper(groupID: group.id, fileID: file.id)
                            }
                        }
                        Button(
                            "Remove \(group.files.count - 1) Other Cop\(group.files.count == 2 ? "y" : "ies")… (\(ByteSizeFormatter.format(group.reclaimableBytes)))"
                        ) {
                            openDuplicateReview(
                                [group],
                                subtitle: "Keeping \(group.keeper?.url.lastPathComponent ?? "one copy")."
                            )
                        }
                        .font(.caption)
                    }
                }
            }.careResults()
        }
    }

    /// Builds the plan from the groups as they are on disk *now*. A set whose
    /// kept copy has been moved, deleted or edited since the scan is dropped
    /// — its other copies may be the only ones left.
    private func openDuplicateReview(_ groups: [DuplicateFinder.DuplicateGroup], subtitle: String) {
        let plan = DuplicateFinder.duplicatePlan(for: groups)
        let stale = groups.filter { DuplicateFinder.stillValid($0) == nil }
        if !stale.isEmpty {
            coordinator.removeDuplicateGroups(ids: Set(stale.map(\.id)))
        }
        guard !plan.items.isEmpty else {
            staleNotice = true
            return
        }
        var note = subtitle
        if !stale.isEmpty {
            note += " \(stale.count) set\(stale.count == 1 ? " has" : "s have") changed since the scan and \(stale.count == 1 ? "was" : "were") left out."
        }
        review = ReviewRequest(plan: plan, title: "Remove Duplicates", subtitle: note, action: "duplicates")
    }

    /// Sets of pictures that look alike. Nothing is ticked for you: which
    /// one is "the good one" is your call.
    @ViewBuilder
    private var similarList: some View {
        if let report = model.similar {
            if report.groups.isEmpty {
                CareEmptyState(
                    "No Similar Pictures",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("None of the pictures in your scanned folders look alike.")
                )
            } else {
                List {
                    ForEach(report.groups) { group in
                        Section {
                            ForEach(group.files) { file in
                                SimilarPhotoRow(file: file, isLargest: file.id == group.files.first?.id, isSelected: Binding(
                                    get: { selectedSimilar.contains(file.id) },
                                    set: { isOn in
                                        if isOn {
                                            selectedSimilar.insert(file.id)
                                        } else {
                                            selectedSimilar.remove(file.id)
                                        }
                                    }
                                ))
                            }
                        } header: {
                            HStack {
                                Text("\(group.files.count) similar pictures")
                                Spacer()
                                Button("Select All but the Largest") {
                                    selectedSimilar.formUnion(group.files.dropFirst().map(\.id))
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    if report.skippedOverLimit > 0 {
                        Text(
                            "\(report.skippedOverLimit.formatted()) smaller pictures weren't compared — only the \(SimilarImageFinder.maximumImages.formatted()) largest are."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .careResults()

                HStack {
                    let selected = report.groups.flatMap(\.files).filter { selectedSimilar.contains($0.id) }
                    Text(selected.isEmpty
                        ? "Tick the pictures you want to remove. Look before you choose — similar isn't identical."
                        : "\(selected.count) selected · \(ByteSizeFormatter.format(selected.reduce(0) { $0 + $1.sizeBytes }))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review Selected…") {
                        review = ReviewRequest(
                            plan: DuplicateFinder.largeFilePlan(for: selected),
                            title: "Remove Similar Pictures",
                            subtitle: "These go to the Trash. They are similar to pictures you're keeping, not identical.",
                            action: "similarPhotos"
                        )
                    }
                    .carePrimaryAction()
                    .tint(tint)
                    .disabled(selected.isEmpty)
                }
                .padding()
            }
        } else if model.isScanning {
            Spacer()
        } else {
            CareEmptyState("A fresh look at your pictures.", systemImage: "photo.on.rectangle.angled", description: Text(
                "Find pictures that look alike, including resized copies and re-saved exports. Analysis stays on this Mac; your Photos library is not touched."
            )) {
                Button("Find Similar Pictures") { model.findSimilar() }.carePrimaryAction().disabled(activity.isBusy)
            }
        }
    }

    @ViewBuilder
    private var largeFilesList: some View {
        if largeFiles.isEmpty {
            CareEmptyState(
                "No Large Files Found",
                systemImage: "checkmark.circle",
                description: Text(
                    "Nothing over \(ByteSizeFormatter.formatRounded(DuplicateFinder.largeFileThreshold)) in your scanned folders. Change the size in Settings."
                )
            )
        } else {
            List(largeFiles) { file in
                LargeFileRow(file: file, isSelected: Binding(
                    get: { selectedLargeFiles.contains(file.id) },
                    set: { isOn in
                        if isOn {
                            selectedLargeFiles.insert(file.id)
                        } else {
                            selectedLargeFiles.remove(file.id)
                        }
                    }
                ))
            }.careResults()

            HStack {
                let selected = largeFiles.filter { selectedLargeFiles.contains($0.id) }
                Text(selected.isEmpty
                    ? "Tick the files you want to remove."
                    : "\(selected.count) selected · \(ByteSizeFormatter.format(selected.reduce(0) { $0 + $1.sizeBytes }))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Review Selected…") {
                    review = ReviewRequest(
                        plan: DuplicateFinder.largeFilePlan(for: selected),
                        title: "Remove Large Files",
                        action: "largeFiles"
                    )
                }
                .carePrimaryAction()
                .tint(tint)
                .disabled(selected.isEmpty)
            }
            .padding()
        }
    }
}

private struct DuplicateFileRow: View {
    let file: DuplicateFinder.FileEntry
    let isKeeper: Bool
    let tint: Color
    let onKeep: () -> Void

    var body: some View {
        Button(action: onKeep) {
            HStack {
                Image(systemName: isKeeper ? "star.fill" : "star")
                    .foregroundStyle(isKeeper ? .yellow : .secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(file.url.lastPathComponent).lineLimit(1)
                    Text(file.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let modified = file.modified {
                    Text(modified.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(isKeeper ? "Keep" : "Remove")
                    .font(.caption.bold())
                    .foregroundStyle(isKeeper ? tint : .secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.url.path)
        .contextMenu { PathMenu(url: file.url) }
        .accessibilityLabel("\(file.url.lastPathComponent) in \(file.url.deletingLastPathComponent().lastPathComponent)")
        .accessibilityValue(isKeeper ? "Will be kept" : "Will be removed")
        .accessibilityHint(isKeeper ? "" : "Keeps this copy instead")
    }
}

private struct LargeFileRow: View {
    let file: DuplicateFinder.FileEntry
    @Binding var isSelected: Bool

    var body: some View {
        HStack {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading) {
                Text(file.url.lastPathComponent).lineLimit(1)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let modified = file.modified {
                Text(modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(ByteSizeFormatter.format(file.sizeBytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
        .help(file.url.path)
        .contextMenu { PathMenu(url: file.url) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.url.lastPathComponent), \(ByteSizeFormatter.format(file.sizeBytes))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isSelected.toggle() }
    }
}

private struct SimilarPhotoRow: View {
    let file: DuplicateFinder.FileEntry
    let isLargest: Bool
    @Binding var isSelected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Select \(file.url.lastPathComponent)")
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).lineLimit(1)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isLargest {
                    Text("Largest in this set")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let modified = file.modified {
                Text(modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(ByteSizeFormatter.format(file.sizeBytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .help(file.url.path)
        .contextMenu { PathMenu(url: file.url) }
        .task(id: file.id) { thumbnail = await ThumbnailCache.load(file.url) }
    }
}
