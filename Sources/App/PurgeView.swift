import SwiftUI
import Core
import Features
import UI

struct PurgeView: View {
    @State private var artifacts: [ProjectArtifactScanner.Artifact] = []
    @State private var selectedArtifacts: Set<String> = []
    @State private var scanning = false
    @State private var purgePlan: SafeFileDeleter.Plan?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
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
                    HStack {
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedArtifacts.contains(artifact.id) {
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
            PlanReviewView(plan: plan, title: "Purge") { dryRun in
                let result = SafeFileDeleter.shared.execute(plan, mode: .trash, dryRun: dryRun, action: "purge")
                print("Purge \(dryRun ? "preview" : "done"): freed \(ByteSizeFormatter.format(result.freedBytes))")
                purgePlan = nil
            }
        }
    }
}