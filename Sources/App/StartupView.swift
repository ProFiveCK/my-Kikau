import AppKit
import SwiftUI
import Core
import Features
import UI

/// What starts in the background: launch agents and daemons, grouped by who
/// they run for. The user's own agents can be removed; system-wide ones are
/// shown so you can see what's there.
struct StartupView: View {
    @State private var items: [StartupItems.Item]?
    @State private var selection: Set<String> = []
    @State private var review: ReviewRequest?
    @State private var loading = false

    private let tint = ContentView.SidebarItem.startup.tint

    private var subtitle: String {
        guard let items else { return "Background items that start with your Mac" }
        let broken = items.filter { $0.programMissing && $0.isRemovable }.count
        return "\(items.count) background items" + (broken > 0 ? " · \(broken) pointing at software that's gone" : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Startup Items", subtitle: subtitle, systemImage: ContentView.SidebarItem.startup.icon, tint: tint) {
                Button("Login Items Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("Apps that open at login, and apps allowed to run in the background, are managed in System Settings")
                Button(items == nil ? "Scan" : "Refresh") { load() }
                    .keyboardShortcut("r", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .disabled(loading)
            }

            if let items {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Background Items",
                        systemImage: "checkmark.circle",
                        description: Text("No launch agents or daemons are installed.")
                    )
                } else {
                    List {
                        ForEach([StartupItems.Scope.user, .systemAgent, .systemDaemon], id: \.self) { scope in
                            let scoped = items.filter { $0.scope == scope }
                            if !scoped.isEmpty {
                                Section {
                                    ForEach(scoped) { item in
                                        StartupRow(item: item, isSelected: Binding(
                                            get: { selection.contains(item.id) },
                                            set: { isOn in
                                                if isOn {
                                                    selection.insert(item.id)
                                                } else {
                                                    selection.remove(item.id)
                                                }
                                            }
                                        ))
                                    }
                                } header: {
                                    Text(header(for: scope))
                                }
                            }
                        }
                    }

                    HStack {
                        let selected = items.filter { selection.contains($0.id) && $0.isRemovable }
                        Text(selected.isEmpty
                            ? "Tick items under “For You” to remove them. System-wide items need an administrator."
                            : "\(selected.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Select Broken") {
                            selection = Set(items.filter { $0.programMissing && $0.isRemovable }.map(\.id))
                        }
                        .disabled(!items.contains { $0.programMissing && $0.isRemovable })
                        Button("Remove Selected…") {
                            review = ReviewRequest(
                                plan: StartupItems.removalPlan(for: selected),
                                title: "Remove Startup Items",
                                subtitle: "Each item is stopped, then its file moves to the Trash. The software it belongs to is not removed.",
                                action: "startup"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                        .disabled(selected.isEmpty)
                    }
                    .padding()
                }
            } else if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Not Scanned Yet", systemImage: "power")
                } description: {
                    Text("See which helpers and updaters are set to start in the background, and remove the ones you don't need.")
                } actions: {
                    Button("Scan") { load() }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                }
            }
        }
        .sheet(item: $review) { request in
            PlanReviewView(
                plan: request.plan,
                title: request.title,
                subtitle: request.subtitle,
                action: request.action,
                prepare: { simulate, selectedIDs in
                    guard !simulate else { return [] }
                    let toStop = (items ?? []).filter { selectedIDs.contains($0.id) }
                    for item in toStop {
                        await StartupItems.stop(item)
                    }
                    return toStop.isEmpty ? [] : ["\(toStop.count) item(s) stopped"]
                },
                onClose: { result in
                    review = nil
                    if let result, !result.dryRun, !result.removedIDs.isEmpty {
                        selection.subtract(result.removedIDs)
                        load()
                    }
                }
            )
        }
        .task {
            if items == nil {
                load()
            }
        }
    }

    private func header(for scope: StartupItems.Scope) -> String {
        switch scope {
        case .user: "For You — start when you log in"
        case .systemAgent: "All Users — start when anyone logs in"
        case .systemDaemon: "System — start when the Mac starts"
        }
    }

    private func load() {
        loading = true
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { StartupItems.scan() }.value
            items = scanned
            selection = selection.intersection(scanned.map(\.id))
            loading = false
        }
    }
}

private struct StartupRow: View {
    let item: StartupItems.Item
    @Binding var isSelected: Bool

    private var detail: String {
        var parts: [String] = []
        if let owner = item.owningAppName {
            parts.append(owner)
        }
        if let program = item.program {
            parts.append(program)
        }
        return parts.isEmpty ? item.url.lastPathComponent : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isRemovable)
                .accessibilityLabel("Select \(item.label)")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if item.programMissing {
                Label("Software missing", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if item.isProtected {
                Label("Protected", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if item.runsAtLoad {
                Text("Runs at start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(item.url.path)
        .contextMenu { PathMenu(url: item.url) }
    }
}
