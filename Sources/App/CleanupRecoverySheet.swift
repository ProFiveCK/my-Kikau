import SwiftUI
import Core
import UI

struct CleanupRecoverySheet: View {
    let session: CleanupSession
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var work = WorkCoordinator.shared
    @State private var items: [CleanupRecovery.Item] = []
    @State private var selection: Set<String> = []
    @State private var loading = true
    @State private var running = false
    @State private var results: [CleanupRecovery.Result]?
    @State private var restoreTask: Task<Void, Never>?

    private var chosen: [CleanupRecovery.Item] {
        items.filter { $0.isAvailable && selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore files from this cleanup").font(.title2.bold())
            Text(session.date.formatted(date: .complete, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
            Text("Choose the exact files to put back. Existing files are never replaced. This restores files only; it does not undo settings or restart removed app services.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let results {
                Text("\(results.filter(\.restored).count) restored · \(results.filter { !$0.restored }.count) couldn’t be restored · \(max(0, chosen.count - results.count)) not attempted")
                    .font(.headline)
                List(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(result.message, systemImage: result.restored ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(result.restored ? Color.green : Color.orange)
                        Text(result.path).font(.caption).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            } else {
                List(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("Restore \(item.entry.path)", isOn: Binding(
                            get: { selection.contains(item.id) },
                            set: {
                                if $0 {
                                    selection.insert(item.id)
                                } else {
                                    selection.remove(item.id)
                                }
                            }
                        )).labelsHidden().toggleStyle(.checkbox).disabled(!item.isAvailable || running)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: item.entry.path).lastPathComponent).fontWeight(.medium)
                            Text("To: \(item.entry.path)").font(.caption).textSelection(.enabled)
                            if let reason = item.unavailableReason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            } else if let path = item.entry.trashedPath {
                                Text("From: \(path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }.padding(.vertical, 5)
                }
            }
            Text("Recovery uses retained local history and files still in the Trash. Emptying the Trash or clearing history removes this recovery option.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if running {
                    ProgressView().controlSize(.small); Text("Restoring files…").font(.caption)
                }
                Spacer()
                if running {
                    Button("Stop after current file") { restoreTask?.cancel() }
                } else {
                    Button(results == nil ? "Cancel" : "Done") { onDone(); dismiss() }
                    if results == nil {
                        Button { restore() } label: {
                            Text("Restore \(chosen.count) \(chosen.count == 1 ? "File" : "Files")").foregroundStyle(CareTheme.onAccent)
                        }
                        .buttonStyle(.borderedProminent).disabled(chosen.isEmpty || loading || work.isBusy)
                    }
                }
            }
        }.padding(24).frame(width: 680, height: 570).background(CareTheme.background).tint(CareTheme.accent)
            .interactiveDismissDisabled(running)
            .task {
                let session = session
                let loaded = await Task.detached { CleanupRecovery.preview(session) }.value
                items = loaded
                selection = Set(loaded.filter(\.isAvailable).map(\.id))
                loading = false
            }
    }

    private func restore() {
        guard let lease = work.begin("Restoring cleanup files", kind: .deletion, cancel: { restoreTask?.cancel() }) else { return }
        let reviewed = chosen
        running = true
        restoreTask = Task {
            defer { work.finish(lease); running = false; restoreTask = nil }
            results = await CleanupRecovery.restore(reviewed)
        }
    }
}
