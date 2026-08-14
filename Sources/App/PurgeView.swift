import SwiftUI
import Core
import Features
import UI

struct PurgeView: View {
    @State private var artifacts: [ProjectArtifactScanner.Artifact] = []
    @State private var selectedArtifacts: Set<String> = []
    @State private var scanning = false
    @State private var purgePlan: SafeFileDeleter.Plan?

    private let tint = ContentView.SidebarItem.purge.tint

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: ContentView.SidebarItem.purge.icon)
                    .foregroundStyle(tint)
                Text("Project Purge").font(.title2).bold()
                Spacer()
                Button(scanning ? "Scanning..." : "Scan Projects") {
                    scanning = true
                    Task.detached(priority: .userInitiated) {
                        let result = ProjectArtifactScanner.scan()
                        await MainActor.run {
                            artifacts = result
                            scanning = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(scanning)
            }
            .padding()

            if artifacts.isEmpty && !scanning {
                ContentUnavailableView(
                    "No Projects Scanned",
                    systemImage: "hammer",
                    description: Text("Click Scan Projects to find node_modules, build, target, and other artifacts.")
                )
            } else {
                List(artifacts) { artifact in
                    let isSelected = selectedArtifacts.contains(artifact.id)
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? tint : .secondary)
                        Image(systemName: artifact.isRecent ? "clock" : "hammer")
                            .foregroundStyle(artifact.isRecent ? .orange : .secondary)
                        VStack(alignment: .leading) {
                            Text(artifact.projectName)
                            Text("\(artifact.artifactType) · \(ByteSizeFormatter.format(artifact.sizeBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        isSelected ? tint.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelected {
                            selectedArtifacts.remove(artifact.id)
                        } else {
                            selectedArtifacts.insert(artifact.id)
                        }
                    }
                }

                if !selectedArtifacts.isEmpty {
                    HStack {
                        Text("\(selectedArtifacts.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Review Plan") {
                            let selected = artifacts.filter { selectedArtifacts.contains($0.id) }
                            purgePlan = ProjectArtifactScanner.plan(for: selected)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $purgePlan) { plan in
            PlanReviewView(plan: plan, title: "Purge", onCancel: { purgePlan = nil }) { dryRun in
                _ = SafeFileDeleter.shared.execute(plan, mode: .trash, dryRun: dryRun, action: "purge")
                purgePlan = nil
            }
        }
        .onAppear {
            // Adopt a scan already run from the Status dashboard's "Scan
            // Everything" instead of forcing a redundant rescan.
            if artifacts.isEmpty, let cached = ScanEverythingCoordinator.shared.purgeArtifacts {
                artifacts = cached
            }
        }
    }
}