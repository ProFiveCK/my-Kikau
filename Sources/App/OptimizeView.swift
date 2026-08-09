import SwiftUI
import Core
import Features

struct OptimizeView: View {
    @State private var selectedTasks: Set<String> = []
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Maintenance").font(.title2).bold()
                Spacer()
                Button(running ? "Running..." : "Run Selected") {
                    running = true
                    // Execute selected tasks (stub — real execution requires Process spawning)
                    print("Selected: \(selectedTasks)")
                    running = false
                }
                .disabled(selectedTasks.isEmpty || running)
            }
            .padding()

            List(MaintenanceCatalog.tasks, selection: $selectedTasks) { task in
                VStack(alignment: .leading) {
                    HStack {
                        Text(task.name).font(.body)
                        if task.requiresSudo {
                            Image(systemName: "lock")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(task.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(task.id)
            }
        }
    }
}