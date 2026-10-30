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
    private var selectedAppIDs: Set<String> {
        get { model.selectedAppIDs }
        nonmutating set { model.selectedAppIDs = newValue }
    }

    @ObservedObject private var activity = WorkCoordinator.shared
    @State private var searchText = ""
    /// Column sort; size first, largest on top — the reason most people open
    /// an uninstaller.
    @State private var sortOrder = [KeyPathComparator(\AppInventory.AppInfo.sizeBytes, order: .reverse)]
    @State private var filter: Filter = .all
    /// Explicit focus control for the search field. Without this, clicking
    /// into the field could silently fail to accept keystrokes: macOS's
    /// NavigationSplitView sidebar is a `List(selection:)`, and AppKit can
    /// leave/return first-responder status there instead of transferring it
    /// to the TextField on click — a known SwiftUI-on-macOS quirk. Binding
    /// `.focused()` and setting it explicitly on tap forces the transfer
    /// rather than relying on SwiftUI's automatic click-to-focus.
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
        /// The administrator helper is available, so items owned by root are
        /// planned too and can be retried through it.
        let helperEnabled: Bool
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All Apps"
        case unused = "Unused 3+ Months"
        case large = "Larger Than 500 MB"
        case appStore = "From the App Store"
        case updates = "Updates Available"
        var id: String {
            rawValue
        }
    }

    private static let largeAppBytes: Int64 = 500_000_000

    private let tint = ContentView.SidebarItem.uninstall.tint

    private var apps: [AppInventory.AppInfo] {
        coordinator.apps ?? []
    }

    /// Ticked apps that still exist and can be uninstalled.
    private var selectedApps: [AppInventory.AppInfo] {
        apps.filter { selectedAppIDs.contains($0.id) && !AppInventory.isProtected($0) }
    }

    private var subtitle: String {
        if model.isScanning {
            return "Listing installed apps…"
        }
        guard coordinator.apps != nil else { return "Remove apps together with the files they leave behind" }
        let total = apps.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var text = "\(apps.count) apps · \(ByteSizeFormatter.format(total)) total"
        if model.lastUpdateCheck != nil {
            let report = model.report(for: apps)
            let unchecked = apps.count - report.statuses.count
            text += " · " + report.summary + (unchecked > 0 ? " · \(unchecked) not checked" : "")
        }
        return text
    }

    private func visibleApps() -> [AppInventory.AppInfo] {
        var result = apps
        switch filter {
        case .all: break
        case .unused: result = result.filter { $0.staleUseBucket != nil }
        case .large: result = result.filter { $0.sizeBytes >= Self.largeAppBytes }
        case .appStore: result = result.filter(\.isAppStore)
        case .updates: result = result.filter { model.updates[$0.id] != nil }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || ($0.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        return result.sorted(using: sortOrder)
    }

    var body: some View {
        let visible = visibleApps()
        let selected = selectedApps
        VStack(spacing: 0) {
            ScreenHeader("Applications", subtitle: subtitle, systemImage: ContentView.SidebarItem.uninstall.icon, tint: tint) {
                if preparing || findingOrphans {
                    ProgressView().controlSize(.small)
                }
                if model.isCheckingUpdates {
                    Button("Stop Checking\(model.updateProgress.map { " (\($0))" } ?? "")") { model.cancelUpdateCheck() }
                } else if coordinator.apps != nil, !ManagedPolicy.shared.disableNetworkLookups {
                    Button("Check for Updates") { model.checkForUpdates(apps) }
                        .help(
                            "Asks each app's own update feed, and the App Store, whether a newer version exists. "
                                + "myKikau doesn't install anything."
                        )
                        .disabled(activity.isBusy)
                }
                Button("Find Leftovers…") { findOrphans() }
                    .help("Looks for files left behind by apps that are no longer installed")
                    .disabled(findingOrphans || preparing || activity.isBusy)
                Button(coordinator.apps == nil ? "Scan Apps" : "Rescan") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .carePrimaryAction()
                    .tint(tint)
                    .disabled(activity.isBusy)
            }

            if coordinator.apps != nil {
                CareSummary([
                    ("Applications", apps.count.formatted()),
                    ("Installed size", ByteSizeFormatter.format(coordinator.appFootprintBytes)),
                    ("Selected", selected.count.formatted()),
                ])
            }
            if let coverage = coordinator.coverage[.apps] {
                ScanCoverageView(coverage).padding(.horizontal).padding(.bottom, 8)
            }
            if coordinator.apps != nil {
                filterBar
            }

            if model.isScanning {
                ScanProgressBar("Measuring installed apps", onCancel: activity.canCancel ? { activity.cancel() } : nil)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            if model.isScanning, apps.isEmpty {
                Spacer()
            } else if coordinator.apps == nil {
                CareEmptyState("Space for the apps you use", systemImage: "app.dashed", description: Text(
                    "List installed applications, see which are large or unused, and remove them with their leftovers."
                )) {
                    Button("Scan Apps") { model.scan() }.carePrimaryAction().disabled(activity.isBusy)
                }
            } else if visible.isEmpty {
                if searchText.isEmpty {
                    CareEmptyState(
                        "No Apps Match",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("No installed app fits the “\(filter.rawValue)” filter.")
                    )
                } else {
                    CareEmptyState(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No installed app matches “\(searchText)”.")
                    )
                }
            } else {
                appsTable(visible).careResults()

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
                        .careDestructiveAction()
                        .disabled(preparing || activity.isBusy)
                    }
                    .padding()
                }
            }
        }
        .careScreen()
        .onAppear { model.reconcileSelection() }
        .onChange(of: coordinator.apps) { _, _ in model.reconcileSelection() }
        .sheet(item: $pending) { item in
            PlanReviewView(
                plan: item.plan,
                title: item.apps.count == 1 ? "Uninstall \(item.apps[0].name)" : "Uninstall \(item.apps.count) Apps",
                subtitle: reviewSubtitle(for: item),
                action: "uninstall",
                prepare: { simulate, selectedIDs in
                    await prepare(item, simulate: simulate, selectedIDs: selectedIDs)
                },
                // Only when the administrator helper is installed and approved.
                elevate: item.helperEnabled ? { paths in
                    await PrivilegedHelperClient.removeItems(
                        paths,
                        sizes: Dictionary(uniqueKeysWithValues: item.plan.items.map { ($0.url.path, $0.sizeBytes) }),
                        logAction: "uninstall.admin"
                    )
                } : nil,
                onClose: { result in
                    if let result, !result.dryRun {
                        for app in item.apps where result.removedIDs.contains(app.url.path) {
                            coordinator.removeApp(id: app.id)
                            selectedAppIDs.remove(app.id)
                        }
                        if !result.removedIDs.isEmpty {
                            AnalyzeScanSession.shared.markStale()
                        }
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
            isPresented: Binding(get: { quitPrompt != nil }, set: {
                if !$0 {
                    quitPrompt = nil
                }
            }),
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
                    Text(LocalizedStringKey(option.rawValue)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 190)
            .accessibilityLabel("Filter apps")
        }
        .careToolbar()
    }

    /// Rows are selected the native way (click, ⇧-click, ⌘-click, ⌘A);
    /// column headers sort.
    private func appsTable(_ visible: [AppInventory.AppInfo]) -> some View {
        Table(visible, selection: $model.selectedAppIDs, sortOrder: $sortOrder) {
            TableColumn("Application", value: \.name, comparator: .localizedStandard) { app in
                AppNameCell(app: app)
            }
            .width(min: 160, ideal: 210, max: 500)
            TableColumn("Last Used", value: \.lastUsedSortKey) { app in
                LastUsedCell(app: app)
            }
            .width(min: 76, ideal: 88, max: 110)
            TableColumn("Update") { app in
                UpdateCell(app: app, status: model.status(for: app))
            }
            .width(min: 82, ideal: 92, max: 140)
            TableColumn("Size", value: \.sizeBytes) { app in
                SizeCell(bytes: app.sizeBytes)
            }
            .width(min: 62, ideal: 68, max: 100)
            .alignment(.trailing)
            TableColumn("") { app in
                UninstallCell(app: app, disabled: preparing || activity.isBusy) { beginUninstall([app]) }
            }
            .width(80)
        }
        .contextMenu(forSelectionType: AppInventory.AppInfo.ID.self) { ids in
            if ids.count == 1, let app = apps.first(where: { $0.id == ids.first }) {
                PathMenu(url: app.url)
            }
        } primaryAction: { ids in
            if ids.count == 1, let app = apps.first(where: { $0.id == ids.first }) {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
        }
    }

    private func reviewSubtitle(for item: PendingUninstall) -> String {
        var parts: [String] = []
        if item.apps.count == 1, let app = item.apps.first {
            if !item.appsWithOtherCopy.isEmpty {
                parts
                    .append(
                        "Another copy of \(app.name) is installed, so its settings, data and background services are left in place. Only this copy is removed."
                    )
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
            parts.append(item.helperEnabled
                ? "Apps installed for all users need an administrator password; you'll be asked after the first pass."
                : "Apps installed for all users may be refused; drag those to the Trash in Finder instead.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Flow

    private func beginUninstall(_ targets: [AppInventory.AppInfo]) {
        guard !activity.isBusy else { return }
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
            for _ in 0 ..< 25 where targets.contains(where: AppInventory.isRunning) {
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
        guard let lease = activity.begin("Preparing app review") else { preparing = false; return }
        preparing = true
        Task {
            defer { activity.finish(lease) }
            let item = await Task.detached(priority: .userInitiated) { () -> PendingUninstall in
                let helperEnabled = PrivilegedHelperClient.isEnabled
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
                // With the helper, system-wide launch plists and helper tools
                // join the plan (they fail the first pass, then go through
                // the helper). Without it they're only reported.
                if helperEnabled, !systemItems.isEmpty {
                    plans.append(SafeFileDeleter.shared.preview(systemItems, category: .leftover))
                    systemItems = []
                }
                return PendingUninstall(
                    apps: targets,
                    plan: .merged(plans),
                    systemLevelItems: systemItems,
                    appsWithOtherCopy: withOtherCopy,
                    helperEnabled: helperEnabled
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
        if loginItems > 0 {
            notes.insert("\(loginItems) “Open at Login” entr\(loginItems == 1 ? "y" : "ies") \(verb) removed", at: 0)
        }
        if helpers > 0 {
            notes.insert("\(helpers) login helper(s) \(verb) stopped", at: 0)
        }
        if agents > 0 {
            notes.insert("\(agents) background agent(s) \(verb) stopped", at: 0)
        }
        if !item.systemLevelItems.isEmpty {
            let names = item.systemLevelItems.map(\.lastPathComponent).joined(separator: ", ")
            notes.append("Left in place (needs an administrator): \(names)")
        }
        return notes
    }

    /// Looks for files left by apps that are no longer installed. Nothing is
    /// ticked by default: without the app to read, the match is a suggestion.
    private func findOrphans() {
        guard let lease = activity.begin("Finding app leftovers") else { return }
        findingOrphans = true
        Task {
            defer { activity.finish(lease) }
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

private struct UpdateCell: View {
    let app: AppInventory.AppInfo
    let status: AppUpdateChecker.CheckStatus?

    var body: some View {
        if case let .available(update) = status {
            Button {
                // The app updates itself; an App Store app updates from
                // its store page.
                NSWorkspace.shared.open(update.storeURL ?? app.url)
            } label: {
                Label(update.latestVersion, systemImage: "arrow.down.circle.fill")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help(update.storeURL == nil
                ? "Version \(update.latestVersion) is available — opens the app so it can update itself"
                : "Version \(update.latestVersion) is available — opens its App Store page")
            .accessibilityLabel("Update \(app.name) to \(update.latestVersion)")
        } else {
            Text(status?.label ?? "Not checked")
                .font(.caption)
                .foregroundStyle(status?.label == "Check failed" ? Color.orange : .secondary)
                .help(status?.detail ?? "Run Check for Updates to query the app’s update source.")
        }
    }
}

private struct AppNameCell: View {
    let app: AppInventory.AppInfo

    private var protectionReason: String? {
        AppInventory.protectionReason(app)
    }

    var body: some View {
        let protected = protectionReason != nil
        HStack(spacing: 10) {
            Image(nsImage: AppIconCache.icon(for: app.url))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).font(.subheadline.bold())
                    if let version = app.version {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let bundleID = app.bundleID {
                        Text(bundleID).foregroundStyle(CareTheme.secondaryInk).lineLimit(1)
                    }
                    if let reason = protectionReason {
                        Label("Protected — \(reason)", systemImage: "lock.shield").foregroundStyle(.secondary)
                    }
                    if app.isAppStore {
                        Text("App Store").foregroundStyle(.secondary)
                    }
                    if app.requiresAdministrator, !protected {
                        Text("For all users").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(protected ? 0.6 : 1)
        .help(app.url.path)
    }
}

private struct LastUsedCell: View {
    let app: AppInventory.AppInfo

    var body: some View {
        Text(app.lastUsed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
            .foregroundStyle(app.staleUseBucket == nil ? Color.secondary : Color.orange)
            .help(app.staleUseBucket ?? "")
    }
}

private struct SizeCell: View {
    let bytes: Int64

    var body: some View {
        Text(ByteSizeFormatter.format(bytes))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct UninstallCell: View {
    let app: AppInventory.AppInfo
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button("Uninstall…", role: .destructive, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(AppInventory.isProtected(app) || disabled)
            .accessibilityLabel("Uninstall \(app.name)")
    }
}

private extension AppInventory.AppInfo {
    /// Sortable "last used": apps never opened sort as oldest.
    var lastUsedSortKey: Date {
        lastUsed ?? .distantPast
    }

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
