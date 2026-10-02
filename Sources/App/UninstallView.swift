import SwiftUI
import AppKit
import Core
import Features
import UI

struct UninstallView: View {
    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var model = AppsModel.shared
    @State private var pending: PendingUninstall?
    @State private var orphanReview: ReviewRequest?
    @State private var preparing = false
    @State private var findingOrphans = false
    @State private var quitPrompt: [AppInventory.AppInfo]?
    @State private var notice: Notice?
    @State private var selectedAppIDs: Set<String> = []
    @State private var searchText = ""
    @State private var sortOption: SortOption = .size
    @State private var filter: Filter = .all
    // Explicit focus control for the search field. Without this, clicking
    // into the field could silently fail to accept keystrokes: macOS's
    // NavigationSplitView sidebar is a `List(selection:)`, and AppKit can
    // leave/return first-responder status there instead of transferring it
    // to the TextField on click — a known SwiftUI-on-macOS quirk. Binding
    // `.focused()` and setting it explicitly on tap forces the transfer
    // rather than relying on SwiftUI's automatic click-to-focus.
    @FocusState private var searchFieldFocused: Bool

    /// One or more apps whose removal plan is open in the review sheet: the
    /// bundles and their leftovers in one list.
    private struct PendingUninstall: Identifiable {
        let id = UUID()
        let apps: [AppInventory.AppInfo]
        let plan: SafeFileDeleter.Plan
        /// Launch daemons and privileged helpers in /Library that need an
        /// administrator to remove — reported, not planned.
        let systemLevelItems: [URL]
        /// Apps with another installed copy (same bundle ID): their data
        /// belongs to that copy too, so only the bundle is planned.
        let appsWithOtherCopy: [AppInventory.AppInfo]
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Size is the default — it's the reason most people open an uninstaller
    /// in the first place.
    private enum SortOption: String, CaseIterable, Identifiable {
        case size = "Size"
        case name = "Name"
        case lastUsed = "Last Used"
        var id: String { rawValue }
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All Apps"
        case unused = "Unused 3+ Months"
        case large = "Larger Than 500 MB"
        case appStore = "From the App Store"
        var id: String { rawValue }
    }

    private static let largeAppBytes: Int64 = 500_000_000

    private let tint = ContentView.SidebarItem.uninstall.tint

    private var apps: [AppInventory.AppInfo] { coordinator.apps ?? [] }

    /// Ticked apps that still exist and can be uninstalled.
    private var selectedApps: [AppInventory.AppInfo] {
        apps.filter { selectedAppIDs.contains($0.id) && !AppInventory.isProtected($0) }
    }

    private var subtitle: String {
        if model.isScanning { return "Listing installed apps…" }
        guard coordinator.apps != nil else { return "Remove apps together with the files they leave behind" }
        let total = apps.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "\(apps.count) apps · \(ByteSizeFormatter.format(total)) total"
    }

    private func visibleApps() -> [AppInventory.AppInfo] {
        var result = apps
        switch filter {
        case .all: break
        case .unused: result = result.filter { $0.staleUseBucket != nil }
        case .large: result = result.filter { $0.sizeBytes >= Self.largeAppBytes }
        case .appStore: result = result.filter(\.isAppStore)
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || ($0.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        switch sortOption {
        case .size:
            return result.sorted { $0.sizeBytes > $1.sizeBytes }
        case .name:
            return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed:
            // Longest-unused first: that's what you're looking for when
            // deciding what to remove.
            return result.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var body: some View {
        let visible = visibleApps()
        let selected = selectedApps
        VStack(spacing: 0) {
            ScreenHeader("Applications", subtitle: subtitle, systemImage: ContentView.SidebarItem.uninstall.icon, tint: tint) {
                if preparing || findingOrphans {
                    ProgressView().controlSize(.small)
                }
                Button("Find Leftovers…") { findOrphans() }
                    .help("Looks for files left behind by apps that are no longer installed")
                    .disabled(findingOrphans || preparing)
                Button(coordinator.apps == nil ? "Scan Apps" : "Rescan") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .disabled(model.isScanning)
            }

            if coordinator.apps != nil {
                filterBar
            }

            if model.isScanning && apps.isEmpty {
                ScanProgressBar("Measuring installed apps")
                    .padding(.horizontal)
                Spacer()
            } else if coordinator.apps == nil {
                ContentUnavailableView {
                    Label("No Apps Listed Yet", systemImage: "app.dashed")
                } description: {
                    Text("List installed applications, see which are large or unused, and remove them with their leftovers.")
                } actions: {
                    Button("Scan Apps") { model.scan() }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                }
            } else if visible.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "No Apps Match",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("No installed app fits the “\(filter.rawValue)” filter.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                List(visible) { app in
                    AppRow(
                        app: app,
                        isSelected: Binding(
                            get: { selectedAppIDs.contains(app.id) },
                            set: { isOn in
                                if isOn { selectedAppIDs.insert(app.id) } else { selectedAppIDs.remove(app.id) }
                            }
                        ),
                        busy: preparing,
                        onUninstall: { beginUninstall([app]) }
                    )
                    .contextMenu { PathMenu(url: app.url) }
                }

                if !selected.isEmpty {
                    HStack {
                        Text("\(selected.count) selected · \(ByteSizeFormatter.format(selected.reduce(0) { $0 + $1.sizeBytes }))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Clear") { selectedAppIDs = [] }
                            .controlSize(.small)
                        Spacer()
                        Button("Uninstall \(selected.count) App\(selected.count == 1 ? "" : "s")…") {
                            beginUninstall(selected)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                        .disabled(preparing)
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $pending) { item in
            PlanReviewView(
                plan: item.plan,
                title: item.apps.count == 1 ? "Uninstall \(item.apps[0].name)" : "Uninstall \(item.apps.count) Apps",
                subtitle: reviewSubtitle(for: item),
                action: "uninstall",
                prepare: { simulate, selectedIDs in
                    await prepare(item, simulate: simulate, selectedIDs: selectedIDs)
                },
                onClose: { result in
                    if let result, !result.dryRun {
                        for app in item.apps where result.removedIDs.contains(app.url.path) {
                            coordinator.removeApp(id: app.id)
                            selectedAppIDs.remove(app.id)
                        }
                        if !result.removedIDs.isEmpty { AnalyzeScanSession.shared.markStale() }
                    }
                    pending = nil
                }
            )
        }
        .sheet(item: $orphanReview) { request in
            PlanReviewView(
                plan: request.plan,
                title: request.title,
                subtitle: request.subtitle,
                action: request.action,
                preselected: request.preselected
            ) { result in
                if let result, !result.dryRun, !result.removedIDs.isEmpty {
                    AnalyzeScanSession.shared.markStale()
                }
                orphanReview = nil
            }
        }
        .confirmationDialog(
            quitPromptTitle,
            isPresented: Binding(get: { quitPrompt != nil }, set: { if !$0 { quitPrompt = nil } }),
            titleVisibility: .visible
        ) {
            if let apps = quitPrompt {
                Button("Quit and Continue") {
                    quitPrompt = nil
                    quitThenReview(apps)
                }
            }
            Button("Cancel", role: .cancel) { quitPrompt = nil }
        } message: {
            Text("An app has to be quit before it can be uninstalled. Save any open work first.")
        }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var quitPromptTitle: String {
        let running = (quitPrompt ?? []).filter(AppInventory.isRunning)
        switch running.count {
        case 0: return "An app is open"
        case 1: return "\(running[0].name) is open"
        default: return "\(running.count) of these apps are open"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search apps or bundle ID", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(6)
            .cardSurface(radius: Theme.Radius.control)
            .contentShape(Rectangle())
            .onTapGesture { searchFieldFocused = true }

            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 190)
            .accessibilityLabel("Filter apps")

            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text("Sort by \(option.rawValue)").tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
            .accessibilityLabel("Sort apps")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func reviewSubtitle(for item: PendingUninstall) -> String {
        var parts: [String] = []
        if item.apps.count == 1, let app = item.apps.first {
            if !item.appsWithOtherCopy.isEmpty {
                parts.append("Another copy of \(app.name) is installed, so its settings, data and background services are left in place. Only this copy is removed.")
            } else {
                let leftovers = item.plan.items.count - 1
                parts.append(leftovers > 0
                    ? "The app and \(leftovers) leftover item\(leftovers == 1 ? "" : "s") it created. Untick anything you want to keep."
                    : "No leftover files were found for this app.")
            }
        } else {
            parts.append("\(item.apps.count) apps and the leftover files they created. Untick anything you want to keep.")
            if !item.appsWithOtherCopy.isEmpty {
                parts.append("Data is kept for apps that have another copy installed.")
            }
        }
        if item.apps.contains(where: \.requiresAdministrator) {
            parts.append("Apps installed for all users may be refused; drag those to the Trash in Finder instead.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Flow

    private func beginUninstall(_ targets: [AppInventory.AppInfo]) {
        let removable = targets.filter { !AppInventory.isProtected($0) }
        guard !removable.isEmpty else { return }
        if removable.contains(where: AppInventory.isRunning) {
            quitPrompt = removable
        } else {
            openReview(for: removable)
        }
    }

    private func quitThenReview(_ targets: [AppInventory.AppInfo]) {
        preparing = true
        Task {
            for app in targets {
                for instance in AppInventory.runningInstances(of: app) {
                    instance.terminate()
                }
            }
            // Give them a few seconds to save and exit.
            for _ in 0..<25 where targets.contains(where: AppInventory.isRunning) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let stillOpen = targets.filter(AppInventory.isRunning)
            if stillOpen.isEmpty {
                openReview(for: targets)
            } else {
                preparing = false
                notice = Notice(
                    title: stillOpen.count == 1 ? "\(stillOpen[0].name) Is Still Open" : "\(stillOpen.count) Apps Are Still Open",
                    message: "\(stillOpen.map(\.name).joined(separator: ", ")) didn't quit — it may be waiting for you to save something. Quit it, then try again."
                )
            }
        }
    }

    private func openReview(for targets: [AppInventory.AppInfo]) {
        preparing = true
        Task {
            let item = await Task.detached(priority: .userInitiated) { () -> PendingUninstall in
                let installed = AppInventory.appBundleURLs()
                var plans: [SafeFileDeleter.Plan] = []
                var systemItems: [URL] = []
                var withOtherCopy: [AppInventory.AppInfo] = []
                for app in targets {
                    let pair = LeftoverFinder.uninstallPlan(app: app)
                    plans.append(pair.appPlan)
                    plans.append(pair.leftoverPlan)
                    if !AppInventory.otherCopies(of: app, among: installed).isEmpty {
                        withOtherCopy.append(app)
                    } else if let bundleID = app.bundleID {
                        systemItems += LeftoverFinder.systemLevelLeftovers(
                            bundleID: bundleID,
                            embeddedBundleIDs: LeftoverFinder.embeddedBundleIDs(appURL: app.url)
                        )
                    }
                }
                return PendingUninstall(
                    apps: targets,
                    plan: .merged(plans),
                    systemLevelItems: systemItems,
                    appsWithOtherCopy: withOtherCopy
                )
            }.value
            preparing = false
            pending = item
        }
    }

    /// Stops each app's background services before its files are moved —
    /// only for apps whose bundle is among the ticked items.
    private func prepare(_ item: PendingUninstall, simulate: Bool, selectedIDs: Set<String>) async -> [String] {
        var agents = 0
        var helpers = 0
        var loginItems = 0
        var notes: [String] = []
        for app in item.apps where selectedIDs.contains(app.url.path) {
            let teardown = await AppTeardown().teardown(app: app, dryRun: simulate)
            agents += teardown.launchAgentsUnloaded.count
            helpers += teardown.loginItemHelpersBootedOut.count
            loginItems += teardown.loginItemsRemoved.count
            if teardown.skippedBecauseOtherCopyInstalled {
                notes.append("\(app.name): background services left running — another copy is installed")
            }
            for error in teardown.errors {
                notes.append("\(app.name): \(error)")
            }
        }
        let verb = simulate ? "would be" : "were"
        if loginItems > 0 { notes.insert("\(loginItems) “Open at Login” entr\(loginItems == 1 ? "y" : "ies") \(verb) removed", at: 0) }
        if helpers > 0 { notes.insert("\(helpers) login helper(s) \(verb) stopped", at: 0) }
        if agents > 0 { notes.insert("\(agents) background agent(s) \(verb) stopped", at: 0) }
        if !item.systemLevelItems.isEmpty {
            let names = item.systemLevelItems.map(\.lastPathComponent).joined(separator: ", ")
            notes.append("Left in place (needs an administrator): \(names)")
        }
        return notes
    }

    /// Looks for files left by apps that are no longer installed. Nothing is
    /// ticked by default: without the app to read, the match is a suggestion.
    private func findOrphans() {
        findingOrphans = true
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                OrphanFinder.plan(for: OrphanFinder.find())
            }.value
            findingOrphans = false
            if plan.items.isEmpty {
                notice = Notice(
                    title: "No Leftovers Found",
                    message: "Nothing in your Library looks like it was left behind by an app that's no longer installed."
                )
            } else {
                orphanReview = ReviewRequest(
                    plan: plan,
                    title: "Leftovers From Removed Apps",
                    subtitle: "These are named after apps that aren't installed any more and haven't changed in three months. Tick the ones you recognise.",
                    action: "uninstall.orphans",
                    preselected: false
                )
            }
        }
    }
}

private struct AppRow: View {
    let app: AppInventory.AppInfo
    @Binding var isSelected: Bool
    let busy: Bool
    let onUninstall: () -> Void

    private var protectionReason: String? { AppInventory.protectionReason(app) }

    var body: some View {
        let protected = protectionReason != nil
        HStack(spacing: 12) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(protected)
                .accessibilityLabel("Select \(app.name)")
            Image(nsImage: AppIconCache.icon(for: app.url))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.subheadline.bold())
                    if let version = app.version {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let bundleID = app.bundleID {
                    Text(bundleID).font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    if let reason = protectionReason {
                        Label("Protected — \(reason)", systemImage: "lock.shield")
                            .foregroundStyle(.secondary)
                    } else if let bucket = app.staleUseBucket {
                        Label(bucket, systemImage: "clock")
                            .foregroundStyle(.orange)
                    } else if let lastUsed = app.lastUsed {
                        Label("Used \(lastUsed.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                    if app.isAppStore {
                        Text("App Store").foregroundStyle(.secondary)
                    }
                    if app.requiresAdministrator && !protected {
                        Text("Installed for all users").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Text(ByteSizeFormatter.format(app.sizeBytes))
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Uninstall…", role: .destructive, action: onUninstall)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(protected || busy)
                .accessibilityLabel("Uninstall \(app.name)")
        }
        .padding(.vertical, 4)
        .opacity(protected ? 0.6 : 1)
    }
}

private extension AppInventory.AppInfo {
    var staleUseBucket: String? {
        guard let lastUsed else { return nil }
        let days = Calendar.current.dateComponents([.day], from: lastUsed, to: Date()).day ?? 0
        switch days {
        case 180...: return "Not used in 6+ months"
        case 90...: return "Not used in 3+ months"
        default: return nil
        }
    }
}
