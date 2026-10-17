import SwiftUI
import Core
import Features
import UI

/// Build artifacts in project folders (`node_modules`, `target`, `build`,
/// `dist`, `.build`, `venv`). A developer feature: shown only when
/// "Developer tools" is on in Settings.
struct PurgeView: View {
    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var model = PurgeModel.shared
    @State private var selectedArtifacts: Set<String> = []
    @State private var review: ReviewRequest?

    @ObservedObject private var activity = WorkCoordinator.shared

    private let tint = ContentView.SidebarItem.purge.tint

    private var artifacts: [ProjectArtifactScanner.Artifact] {
        coordinator.purgeArtifacts ?? []
    }

    private var subtitle: String {
        if model.isScanning {
            return "Looking through your project folders…"
        }
        guard coordinator.purgeArtifacts != nil else { return "Dependencies and build output that the next build recreates" }
        let total = artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return artifacts.isEmpty ? "No build artifacts found" : "\(artifacts.count) folders · \(ByteSizeFormatter.format(total))"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Project Purge", subtitle: subtitle, systemImage: ContentView.SidebarItem.purge.icon, tint: tint) {
                Button(coordinator.purgeArtifacts == nil ? "Scan Projects" : "Rescan") {
                    selectedArtifacts = []
                    model.scan()
                }
                .keyboardShortcut("r", modifiers: .command)
                .carePrimaryAction()
                .tint(tint)
                .disabled(activity.isBusy)
            }

            if !artifacts.isEmpty {
                CareSummary([("Build folders", artifacts.count.formatted()),
                             ("To review", ByteSizeFormatter.format(artifacts.reduce(0) { $0 + $1.sizeBytes })),
                             ("Selected", selectedArtifacts.count.formatted())])
            }
            if model.isScanning {
                ScanProgressBar("Measuring build artifacts")
                    .padding([.horizontal, .bottom])
            }

            if coordinator.purgeArtifacts == nil {
                if model.isScanning {
                    Spacer()
                } else {
                    CareEmptyState("Room for your next build.", systemImage: "hammer", description: Text(
                        "Review dependencies and build output that your tools can recreate. Recently used projects are flagged before you decide."
                    )) {
                        Button("Scan Projects") { model.scan() }.carePrimaryAction().disabled(activity.isBusy)
                    }
                }
            } else if artifacts.isEmpty {
                CareEmptyState(
                    "Nothing to Purge",
                    systemImage: "checkmark.circle",
                    description: Text("No build artifacts were found in your project folders.")
                )
            } else {
                List(artifacts) { artifact in
                    ArtifactRow(artifact: artifact, isSelected: Binding(
                        get: { selectedArtifacts.contains(artifact.id) },
                        set: { isOn in
                            if isOn {
                                selectedArtifacts.insert(artifact.id)
                            } else {
                                selectedArtifacts.remove(artifact.id)
                            }
                        }
                    ))
                }.careResults()

                HStack {
                    let selected = artifacts.filter { selectedArtifacts.contains($0.id) }
                    Text(selected.isEmpty
                        ? "Tick the folders you want to remove."
                        : "\(selected.count) selected · \(ByteSizeFormatter.format(selected.reduce(0) { $0 + $1.sizeBytes }))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select Older Projects") {
                        selectedArtifacts = Set(artifacts.filter { !$0.isRecent }.map(\.id))
                    }
                    Button("Review Selected…") {
                        review = ReviewRequest(
                            plan: ProjectArtifactScanner.plan(for: selected),
                            title: "Purge Build Artifacts",
                            subtitle: "These are recreated the next time each project is built or installed.",
                            action: "purge"
                        )
                    }
                    .carePrimaryAction()
                    .tint(tint)
                    .disabled(selected.isEmpty)
                }
                .padding()
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
                    coordinator.removePurgeArtifacts(ids: result.removedIDs)
                    selectedArtifacts.subtract(result.removedIDs)
                    if !result.removedIDs.isEmpty {
                        AnalyzeScanSession.shared.markStale()
                    }
                }
                review = nil
            }
        }
    }
}

private struct ArtifactRow: View {
    let artifact: ProjectArtifactScanner.Artifact
    @Binding var isSelected: Bool

    var body: some View {
        HStack {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading) {
                Text(artifact.projectName)
                Text(artifact.artifactType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if artifact.isRecent {
                Label("Recently used", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(ByteSizeFormatter.format(artifact.sizeBytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
        .help(artifact.url.path)
        .contextMenu { PathMenu(url: artifact.url) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(artifact.projectName), \(artifact.artifactType), \(ByteSizeFormatter.format(artifact.sizeBytes))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isSelected.toggle() }
    }
}
