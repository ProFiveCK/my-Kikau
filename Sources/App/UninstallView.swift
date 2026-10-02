import SwiftUI
import AppKit
import Core
import Features
import UI

struct UninstallView: View {
    @ObservedObject private var coordinator = ScanEverythingCoordinator.shared
    @ObservedObject private var model = AppsModel.shared
    @State private var pending: PendingUninstall?
    @State private var preparingAppID: String?
    @State private var quitPrompt: AppInventory.AppInfo?
    @State private var notice: Notice?
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

    /// An app whose removal plan is open in the review sheet: the bundle and
    /// its leftovers in one list.
    private struct PendingUninstall: Identifiable {
        let id = UUID()
        let app: AppInventory.AppInfo
        let plan: SafeFileDeleter.Plan
        /// Launch daemons and privileged helpers in /Library that need an
        /// administrator to remove — reported, not planned.
        let systemLevelItems: [URL]
        /// Another bundle with the same bundle ID is installed: the app's
        /// data belongs to that copy too, so only this bundle is planned.
        let otherCopyInstalled: Bool
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
        VStack(spacing: 0) {
            ScreenHeader("Applications", subtitle: subtitle, systemImage: ContentView.SidebarItem.uninstall.icon, tint: tint) {
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
                        isPreparing: preparingAppID == app.id,
                        onUninstall: { beginUninstall(app) }
                    )
                    .contextMenu { PathMenu(url: app.url) }
                }
            }
        }
        .sheet(item: $pending) { item in
            PlanReviewView(
                plan: item.plan,
                title: "Uninstall \(item.app.name)",
                subtitle: reviewSubtitle(for: item),
                action: "uninstall",
                prepare: { simulate, selectedIDs in
                    await prepare(item, simulate: simulate, selectedIDs: selectedIDs)
                },
                onClose: { result in
                    if let result, !result.dryRun {
                        if result.removedIDs.contains(item.app.url.path) {
                            coordinator.removeApp(id: item.app.id)
                        }
                        if !result.removedIDs.isEmpty { AnalyzeScanSession.shared.markStale() }
                    }
                    pending = nil
                }
            )
        }
        .confirmationDialog(
            "\(quitPrompt?.name ?? "This app") is open",
            isPresented: Binding(get: { quitPrompt != nil }, set: { if !$0 { quitPrompt = nil } }),
            titleVisibility: .visible
        ) {
            if let app = quitPrompt {
                Button("Quit \(app.name) and Continue") {
                    quitPrompt = nil
                    quitThenReview(app)
                }
            }
            Button("Cancel", role: .cancel) { quitPrompt = nil }
        } message: {
            Text("It has to be quit before it can be uninstalled. Save any open work first.")
        }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
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
        if item.app.requiresAdministrator {
            return "This app was installed for all users. myKikau can remove its leftovers; if moving the app itself is refused, drag it to the Trash in Finder."
        }
        if item.otherCopyInstalled {
            return "Another copy of \(item.app.name) is installed, so its settings, data and background services are left in place. Only this copy is removed."
        }
        let leftovers = item.plan.items.count - 1
        return leftovers > 0
            ? "The app and \(leftovers) leftover item\(leftovers == 1 ? "" : "s") it created. Untick anything you want to keep."
            : "No leftover files were found for this app."
    }

    // MARK: - Flow

    private func beginUninstall(_ app: AppInventory.AppInfo) {
        if AppInventory.isRunning(app) {
            quitPrompt = app
        } else {
            openReview(for: app)
        }
    }

    private func quitThenReview(_ app: AppInventory.AppInfo) {
        preparingAppID = app.id
        Task {
            for instance in AppInventory.runningInstances(of: app) {
                instance.terminate()
            }
            // Give it a few seconds to save and exit.
            for _ in 0..<25 where AppInventory.isRunning(app) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if AppInventory.isRunning(app) {
                preparingAppID = nil
                notice = Notice(
                    title: "\(app.name) Is Still Open",
                    message: "It didn't quit — it may be waiting for you to save something. Quit it, then try again."
                )
            } else {
                openReview(for: app)
            }
        }
    }

    private func openReview(for app: AppInventory.AppInfo) {
        preparingAppID = app.id
        Task {
            let item = await Task.detached(priority: .userInitiated) { () -> PendingUninstall in
                let plans = LeftoverFinder.uninstallPlan(app: app)
                let otherCopy = !AppInventory.otherCopies(of: app).isEmpty
                let embedded = LeftoverFinder.embeddedBundleIDs(appURL: app.url)
                let systemItems = otherCopy ? [] : (app.bundleID.map {
                    LeftoverFinder.systemLevelLeftovers(bundleID: $0, embeddedBundleIDs: embedded)
                } ?? [])
                return PendingUninstall(
                    app: app,
                    plan: .merged([plans.appPlan, plans.leftoverPlan]),
                    systemLevelItems: systemItems,
                    otherCopyInstalled: otherCopy
                )
            }.value
            preparingAppID = nil
            pending = item
        }
    }

    /// Stops the app's background services before its files are moved — only
    /// if the app bundle itself is among the ticked items.
    private func prepare(_ item: PendingUninstall, simulate: Bool, selectedIDs: Set<String>) async -> [String] {
        var notes: [String] = []
        if selectedIDs.contains(item.app.url.path) {
            let teardown = await AppTeardown().teardown(app: item.app, dryRun: simulate)
            let verb = simulate ? "would be" : "were"
            if !teardown.launchAgentsUnloaded.isEmpty {
                notes.append("\(teardown.launchAgentsUnloaded.count) background agent(s) \(verb) stopped")
            }
            if !teardown.loginItemHelpersBootedOut.isEmpty {
                notes.append("\(teardown.loginItemHelpersBootedOut.count) login helper(s) \(verb) stopped")
            }
            if !teardown.loginItemsRemoved.isEmpty {
                notes.append("“Open at Login” entry \(simulate ? "would be" : "was") removed")
            }
            if teardown.skippedBecauseOtherCopyInstalled {
                notes.append("Background services left running — another copy of the app is installed")
            }
            for error in teardown.errors {
                notes.append("Note: \(error)")
            }
        }
        if !item.systemLevelItems.isEmpty {
            let names = item.systemLevelItems.map(\.lastPathComponent).joined(separator: ", ")
            notes.append("Left in place (needs an administrator): \(names)")
        }
        return notes
    }
}

private struct AppRow: View {
    let app: AppInventory.AppInfo
    let isPreparing: Bool
    let onUninstall: () -> Void

    private var protectionReason: String? { AppInventory.protectionReason(app) }

    var body: some View {
        let protected = protectionReason != nil
        HStack(spacing: 12) {
            Image(nsImage: AppIconCache.icon(for: app.url))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(protected ? 0.6 : 1)
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
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 78)
            } else {
                Button("Uninstall…", role: .destructive, action: onUninstall)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(protected)
                    .accessibilityLabel("Uninstall \(app.name)")
            }
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
