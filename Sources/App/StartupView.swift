import AppKit
import SwiftUI
import Core
import Features
import UI

/// What starts in the background: launch agents and daemons, grouped by who
/// they run for. The user's own agents can be removed directly; system-wide
/// ones only through the administrator helper, which asks for a password.
struct StartupView: View {
    /// Set when System care shows both parts.
    var part: Binding<SystemCareView.Part>?
    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var model = StartupModel.shared
    @ObservedObject private var activity = WorkCoordinator.shared
    private var items: [StartupItems.Item]? {
        coordinator.startupItems
    }

    private var selection: Set<String> {
        get { coordinator.selectedStartupIDs }
        nonmutating set { coordinator.selectedStartupIDs = newValue }
    }

    @State private var review: ReviewRequest?
    /// Read when the screen appears or rescans, not on every render.
    @State private var helperEnabled = false
    private var loading: Bool {
        model.loading
    }

    private let tint = ContentView.SidebarItem.optimize.tint

    private var subtitle: String {
        guard let items else { return "Background items that start with your Mac" }
        let broken = items.filter { $0.programMissing && !$0.isProtected }.count
        return "\(items.count) background items" + (broken > 0 ? " · \(broken) pointing at software that's gone" : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("System care", subtitle: subtitle, systemImage: ContentView.SidebarItem.optimize.icon, tint: tint) {
                if let part {
                    SystemCarePartPicker(part: part)
                }
                Button("Login Items Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("Apps that open at login, and apps allowed to run in the background, are managed in System Settings")
                Button(items == nil ? "Scan" : "Refresh") { load() }
                    .keyboardShortcut("r", modifiers: .command)
                    .carePrimaryAction()
                    .tint(tint)
                    .disabled(activity.isBusy)
            }

            if let items, !items.isEmpty {
                CareSummary([("For you", items.filter { $0.scope == .user }.count.formatted()),
                             ("All users", items.filter { $0.scope == .systemAgent }.count.formatted()),
                             ("System", items.filter { $0.scope == .systemDaemon }.count.formatted())])
            }
            if let coverage = coordinator.coverage[.startup] {
                ScanCoverageView(coverage).padding(.horizontal).padding(.bottom, 8)
            }
            if let items {
                if items.isEmpty {
                    CareEmptyState(
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
                                        StartupRow(item: item, canRemove: item.canRemove(helperEnabled: helperEnabled), isSelected: Binding(
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
                    }.careResults()

                    HStack {
                        let selected = items.filter { selection.contains($0.id) && $0.canRemove(helperEnabled: helperEnabled) }
                        if selected.isEmpty, !helperEnabled {
                            Text("Tick items under “For You” to remove them. System-wide items need the administrator helper.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            AppSettingsButton { Text("Settings…") }
                                .font(.caption)
                                .help("Settings → Advanced → Administrator helper")
                        } else {
                            Text(selected.isEmpty ? "Tick the items you no longer need." : "\(selected.count) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Select Broken") {
                            selection = Set(items.filter { $0.programMissing && $0.canRemove(helperEnabled: helperEnabled) }.map(\.id))
                        }
                        .disabled(!items.contains { $0.programMissing && $0.canRemove(helperEnabled: helperEnabled) })
                        Button("Remove Selected…") {
                            let elevated = selected.contains(where: \.needsAdministrator)
                            review = ReviewRequest(
                                plan: StartupItems.removalPlan(for: selected, helperEnabled: helperEnabled),
                                title: "Remove Startup Items",
                                subtitle: "Each item is stopped, then its file moves to the Trash. "
                                    + "The software it belongs to is not removed."
                                    + (elevated
                                        ? " System-wide items, and the helper tools they run, "
                                        + "need an administrator password after the first pass."
                                        : ""),
                                action: "startup"
                            )
                        }
                        .carePrimaryAction()
                        .tint(tint)
                        .disabled(selected.isEmpty)
                    }
                    .padding()
                }
            } else if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CareEmptyState("A clearer start for your Mac.", systemImage: "power", description: Text(
                    "Review the helpers and updaters that start in the background, and choose which ones you still need."
                )) {
                    Button("Scan Startup Items") { load() }.carePrimaryAction().disabled(activity.isBusy)
                }
            }
        }
        .careScreen()
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
                // Root-owned items fail the first pass; the helper stops each
                // job and moves it after an administrator approves.
                elevate: helperEnabled ? { paths in
                    await PrivilegedHelperClient.removeItems(
                        paths,
                        sizes: Dictionary(uniqueKeysWithValues: request.plan.items.map { ($0.url.path, $0.sizeBytes) }),
                        logAction: "startup.admin"
                    )
                } : nil,
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
            helperEnabled = PrivilegedHelperClient.isEnabled
            if items == nil {
                load()
            }
        }
    }

    private func header(for scope: StartupItems.Scope) -> String {
        switch scope {
        case .user: String(localized: "For You — start when you log in")
        case .systemAgent: String(localized: "All Users — start when anyone logs in")
        case .systemDaemon: String(localized: "System — start when the Mac starts")
        }
    }

    private func load() {
        helperEnabled = PrivilegedHelperClient.isEnabled
        model.scan()
    }
}

private struct StartupRow: View {
    let item: StartupItems.Item
    let canRemove: Bool
    @Binding var isSelected: Bool

    private var detail: String {
        var parts: [String] = []
        if let owner = item.owningAppName {
            parts.append(owner)
        }
        if let program = item.program {
            parts.append(program)
        }
        if item.helperTool != nil {
            parts.append(String(localized: "removes its helper tool too"))
        }
        return parts.isEmpty ? item.url.lastPathComponent : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canRemove)
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
            } else if item.needsAdministrator {
                Label("Administrator", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(canRemove
                        ? "Removing this asks for an administrator password."
                        : "Turn on the administrator helper in Settings → Advanced to remove this.")
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
