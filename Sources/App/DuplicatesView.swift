import SwiftUI
import Core
import Features
import UI

/// Finds duplicate files (true content matches) and separately surfaces
/// large files, across Downloads/Documents/Desktop/Pictures/Movies — the
/// "My Clutter" equivalent, scoped to the user's own content rather than
/// app/system data (that's what Clean and Purge already own).
struct DuplicatesView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case duplicates = "Duplicates"
        case largeFiles = "Large Files"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .duplicates
    @State private var scanning = false
    @State private var duplicateGroups: [DuplicateFinder.DuplicateGroup] = []
    @State private var largeFiles: [DuplicateFinder.FileEntry] = []
    @State private var selectedLargeFiles: Set<String> = []
    @State private var reviewPlan: SafeFileDeleter.Plan?
    // Which duplicate groups `reviewPlan` covers, so the sheet's completion
    // handler knows what to drop from the list afterward — a single group
    // for a per-row "Remove N duplicate(s)", or every group for "Review All".
    @State private var reviewingGroupIDs: Set<String> = []
    // Populated on appear and after every scan. Non-empty means macOS hasn't
    // granted access to one of the folders this feature scans — the most
    // likely explanation for "Duplicates always finds nothing" on a Mac that
    // obviously has files there: `DuplicateFinder.walk()` fails silently in
    // that case (see ProtectedFolderAccessCheck), not with a visible error.
    @State private var deniedFolders: [String] = ProtectedFolderAccessCheck.deniedFolders()

    private let tint = ContentView.SidebarItem.duplicates.tint

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: ContentView.SidebarItem.duplicates.icon)
                    .foregroundStyle(tint)
                Text("Duplicates & Large Files").font(.title2).bold()
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Button(scanning ? "Scanning..." : "Scan") {
                    runScan()
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(scanning)
            }
            .padding()

            if !deniedFolders.isEmpty {
                ProtectedFolderAccessBanner(deniedFolders: deniedFolders)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if duplicateGroups.isEmpty && largeFiles.isEmpty && !scanning {
                ContentUnavailableView(
                    "No Scan Yet",
                    systemImage: "doc.on.doc",
                    description: Text("Scans Downloads, Documents, Desktop, Pictures, and Movies for duplicate and oversized files.")
                )
            } else if mode == .duplicates {
                duplicatesList
            } else {
                largeFilesList
            }
        }
        .sheet(item: $reviewPlan) { plan in
            PlanReviewView(
                plan: plan,
                title: mode == .duplicates ? "Remove Duplicates" : "Remove Large Files",
                onCancel: {
                    reviewPlan = nil
                    reviewingGroupIDs = []
                }
            ) { dryRun in
                let action = mode == .duplicates ? "duplicates" : "largeFiles"
                let result = SafeFileDeleter.shared.execute(plan, mode: .trash, dryRun: dryRun, action: action)
                // Drop what was actually removed from both this view's own
                // list and the dashboard's cache — previously neither
                // updated, so a resolved group/file kept showing here (and
                // on the dashboard) as still reclaimable until the next
                // full Rescan.
                if !dryRun, result.failed == 0 {
                    if mode == .duplicates {
                        duplicateGroups.removeAll { reviewingGroupIDs.contains($0.id) }
                        ScanEverythingCoordinator.shared.removeDuplicateGroups(ids: reviewingGroupIDs)
                    } else {
                        largeFiles.removeAll { selectedLargeFiles.contains($0.id) }
                        ScanEverythingCoordinator.shared.removeLargeFiles(ids: selectedLargeFiles)
                        selectedLargeFiles = []
                    }
                }
                reviewPlan = nil
                reviewingGroupIDs = []
            }
        }
        .onAppear {
            let coordinator = ScanEverythingCoordinator.shared
            if duplicateGroups.isEmpty, let cached = coordinator.duplicateGroups {
                duplicateGroups = cached
            }
            if largeFiles.isEmpty, let cached = coordinator.largeFiles {
                largeFiles = cached
            }
            if let pending = AppNavigation.shared.pendingDuplicatesMode {
                mode = pending == .largeFiles ? .largeFiles : .duplicates
                AppNavigation.shared.pendingDuplicatesMode = nil
            }
        }
    }

    @ViewBuilder
    private var duplicatesList: some View {
        if duplicateGroups.isEmpty && !scanning {
            ContentUnavailableView(
                "No Duplicates Found",
                systemImage: "checkmark.circle",
                description: Text("Nothing duplicated across your scanned folders.")
            )
        } else {
            List {
                Section {
                    HStack {
                        Text("\(duplicateGroups.count) group(s) · \(ByteSizeFormatter.format(totalDuplicateReclaimable)) reclaimable")
                            .font(.subheadline)
                        Spacer()
                        Button("Review All") {
                            reviewingGroupIDs = Set(duplicateGroups.map(\.id))
                            reviewPlan = DuplicateFinder.duplicatePlan(for: duplicateGroups)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                    }
                }
                ForEach(duplicateGroups) { group in
                    Section("\(group.files.count) copies · \(ByteSizeFormatter.format(group.sizeBytes)) each") {
                        ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                            HStack {
                                Image(systemName: index == 0 ? "star.fill" : "doc.on.doc")
                                    .foregroundStyle(index == 0 ? .yellow : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading) {
                                    Text(file.url.lastPathComponent).lineLimit(1)
                                    Text(file.url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        Button("Remove \(group.files.count - 1) duplicate(s), keep newest (\(ByteSizeFormatter.format(group.reclaimableBytes)))") {
                            reviewingGroupIDs = [group.id]
                            reviewPlan = DuplicateFinder.duplicatePlan(for: [group])
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var largeFilesList: some View {
        if largeFiles.isEmpty && !scanning {
            ContentUnavailableView(
                "No Large Files Found",
                systemImage: "checkmark.circle",
                description: Text("Nothing over 100 MB in your scanned folders.")
            )
        } else {
            List(largeFiles) { file in
                let isSelected = selectedLargeFiles.contains(file.id)
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? tint : .secondary)
                    VStack(alignment: .leading) {
                        Text(file.url.lastPathComponent).lineLimit(1)
                        Text(file.url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(ByteSizeFormatter.format(file.sizeBytes))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelected {
                        selectedLargeFiles.remove(file.id)
                    } else {
                        selectedLargeFiles.insert(file.id)
                    }
                }
            }

            if !selectedLargeFiles.isEmpty {
                HStack {
                    Text("\(selectedLargeFiles.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review Plan") {
                        let selected = largeFiles.filter { selectedLargeFiles.contains($0.id) }
                        reviewPlan = DuplicateFinder.largeFilePlan(for: selected)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                }
                .padding()
            }
        }
    }

    private var totalDuplicateReclaimable: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private func runScan() {
        scanning = true
        deniedFolders = ProtectedFolderAccessCheck.deniedFolders()
        Task.detached(priority: .userInitiated) {
            let allFiles = DuplicateFinder.walk()
            let dupes = DuplicateFinder.findDuplicates(allFiles: allFiles)
            let large = DuplicateFinder.findLargeFiles(allFiles: allFiles)
            await MainActor.run {
                duplicateGroups = dupes
                largeFiles = large
                scanning = false
            }
        }
    }
}
