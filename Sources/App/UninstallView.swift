import SwiftUI
import AppKit
import Core
import Features
import UI

struct UninstallView: View {
    @State private var apps: [AppInventory.AppInfo] = []
    @State private var scanning = false
    @State private var selectedApp: AppInventory.AppInfo?
    @State private var appPlan: SafeFileDeleter.Plan?
    @State private var leftoverPlan: SafeFileDeleter.Plan?
    @State private var teardownResult: AppTeardown.TeardownResult?
    @State private var executing = false
    @State private var executionSummary: String?
    @State private var completionAlert: CompletionAlert?
    @State private var searchText = ""
    @State private var sortOption: SortOption = .size
    // Explicit focus control for the search field. Without this, clicking
    // into the field could silently fail to accept keystrokes: macOS's
    // NavigationSplitView sidebar is a `List(selection:)`, and AppKit can
    // leave/return first-responder status there instead of transferring it
    // to the TextField on click — a known SwiftUI-on-macOS quirk. Binding
    // `.focused()` and setting it explicitly on tap forces the transfer
    // rather than relying on SwiftUI's automatic click-to-focus, which is
    // exactly what wasn't reliably happening.
    @FocusState private var searchFieldFocused: Bool

    /// A completion popup at the end of an uninstall — the old small caption
    /// text at the bottom of the list was easy to miss entirely, especially
    /// when it just said something like "1 failed" with no other signal.
    private struct CompletionAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Size is the default — it's the reason most people open an uninstaller
    /// in the first place (largest apps sorts appear before you touch the picker).
    private enum SortOption: String, CaseIterable, Identifiable {
        case size = "Size"
        case name = "Name"
        case lastUsed = "Last Used"
        var id: String { rawValue }
    }

    private let tint = ContentView.SidebarItem.uninstall.tint

    private var staleLargeAppsCount: Int {
        apps.filter {
            $0.staleUseBucket != nil && $0.sizeBytes >= 500_000_000 && !AppInventory.isProtected($0)
        }.count
    }

    private var totalFootprint: Int64 {
        apps.reduce(0) { $0 + $1.sizeBytes }
    }

    private var visibleApps: [AppInventory.AppInfo] {
        let filtered = searchText.isEmpty
            ? apps
            : apps.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || ($0.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        switch sortOption {
        case .size:
            return filtered.sorted { $0.sizeBytes > $1.sizeBytes }
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed:
            return filtered.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: ContentView.SidebarItem.uninstall.icon)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Applications").font(.title2).bold()
                    if !apps.isEmpty {
                        Text("\(apps.count) apps · \(ByteSizeFormatter.format(totalFootprint)) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(scanning ? "Scanning..." : "Scan Apps") {
                    scanning = true
                    Task.detached {
                        let result = AppInventory.scan()
                        await MainActor.run {
                            apps = result
                            scanning = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(scanning)
            }
            .padding()

            if !apps.isEmpty {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
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
                        }
                    }
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { searchFieldFocused = true }

                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if apps.isEmpty && !scanning {
                ContentUnavailableView(
                    "No Apps Scanned",
                    systemImage: "app.dashed",
                    description: Text("Click Scan Apps to list installed applications and find their leftovers.")
                )
            } else if !apps.isEmpty && visibleApps.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(visibleApps) { app in
                    AppRow(app: app, onUninstall: { selectApp(app) })
                        .opacity(AppInventory.isProtected(app) ? 0.5 : 1)
                }
                .safeAreaInset(edge: .bottom) {
                    if staleLargeAppsCount > 0 {
                        Label("\(staleLargeAppsCount) large app(s) have not been used in 3+ months.", systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                    }
                }
            }

            if let summary = executionSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .sheet(item: $appPlan) { plan in
            PlanReviewView(
                plan: plan,
                title: "Uninstall \(selectedApp?.name ?? "")",
                onCancel: {
                    appPlan = nil
                    leftoverPlan = nil
                    selectedApp = nil
                },
                onExecute: { dryRun in
                    handleAppPlanConfirm(dryRun: dryRun)
                }
            )
        }
        .sheet(item: $leftoverPlan) { plan in
            PlanReviewView(
                plan: plan,
                title: "Leftovers — \(selectedApp?.name ?? "")",
                onCancel: { leftoverPlan = nil },
                onExecute: { dryRun in
                    handleLeftoverPlanConfirm(dryRun: dryRun)
                }
            )
        }
        .alert(item: $completionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            if apps.isEmpty, let cached = ScanEverythingCoordinator.shared.apps {
                apps = cached
            }
        }
    }

    private func selectApp(_ app: AppInventory.AppInfo) {
        selectedApp = app
        teardownResult = nil
        executionSummary = nil
        let plans = LeftoverFinder.uninstallPlan(app: app)
        appPlan = plans.appPlan
        leftoverPlan = plans.leftoverPlan
    }

    private func handleAppPlanConfirm(dryRun: Bool) {
        guard let app = selectedApp, let plan = appPlan else {
            appPlan = nil
            return
        }
        appPlan = nil
        executing = true
        Task {
            let teardown = await AppTeardown().teardown(app: app, dryRun: dryRun)
            var summary: [String] = []
            if !teardown.launchAgentsUnloaded.isEmpty {
                summary.append("\(teardown.launchAgentsUnloaded.count) agent(s) unloaded")
            }
            if !teardown.loginItemHelpersBootedOut.isEmpty {
                summary.append("\(teardown.loginItemHelpersBootedOut.count) helper(s) booted out")
            }
            if !teardown.loginItemsRemoved.isEmpty {
                summary.append("\(teardown.loginItemsRemoved.count) login item(s) removed")
            }
            if teardown.unregisteredLaunchServices {
                summary.append("LaunchServices unregistered")
            }
            if !teardown.errors.isEmpty {
                summary.append("\(teardown.errors.count) teardown error(s)")
            }

            if dryRun {
                await MainActor.run {
                    teardownResult = teardown
                    let text = "Dry-run: " + (summary.isEmpty ? "no teardown actions" : summary.joined(separator: ", "))
                    executionSummary = text
                    executing = false
                    completionAlert = CompletionAlert(
                        title: "Preview Complete",
                        message: "\(app.name) — \(text). No files were changed."
                    )
                }
                return
            }

            let deleter = SafeFileDeleter.shared
            let appResult = deleter.execute(plan, mode: .trash, dryRun: false, action: "uninstall.app")
            await MainActor.run {
                if appResult.failed == 0 {
                    apps.removeAll { $0.id == app.id }
                    // Keeps the dashboard's "Apps" pill accurate without
                    // forcing a full Rescan — see ScanEverythingCoordinator.
                    ScanEverythingCoordinator.shared.removeApp(id: app.id)
                }
                teardownResult = teardown
                executionSummary = summary.isEmpty ? "App removed; no teardown actions" : summary.joined(separator: ", ")
                executing = false
                // Present the leftover plan next if there is one — its own
                // completion handler will show the alert in that case, so we
                // only pop the alert here when this is the last step.
                if let lp = leftoverPlan, !lp.isEmpty {
                    leftoverPlan = lp
                } else {
                    let hadIssues = !teardown.errors.isEmpty || appResult.failed > 0
                    completionAlert = CompletionAlert(
                        title: hadIssues ? "Uninstalled with Warnings" : "App Uninstalled",
                        message: hadIssues
                            ? "\(app.name) was removed, but \(appResult.failed + teardown.errors.count) item(s) had issues. \(ByteSizeFormatter.format(appResult.freedBytes)) freed."
                            : "\(app.name) was removed successfully. \(ByteSizeFormatter.format(appResult.freedBytes)) freed."
                    )
                }
            }
        }
    }

    private func handleLeftoverPlanConfirm(dryRun: Bool) {
        guard let plan = leftoverPlan else {
            leftoverPlan = nil
            return
        }
        let appName = selectedApp?.name ?? "App"
        leftoverPlan = nil
        if dryRun {
            executionSummary = (executionSummary ?? "") + " · Leftover dry-run only"
            completionAlert = CompletionAlert(
                title: "Preview Complete",
                message: "\(appName) — leftovers previewed only. No files were changed."
            )
            return
        }
        executing = true
        Task {
            let deleter = SafeFileDeleter.shared
            let res = deleter.execute(plan, mode: .trash, dryRun: false, action: "uninstall.leftovers")
            await MainActor.run {
                executionSummary = (executionSummary ?? "") +
                    " · Leftovers: \(res.succeeded) removed, \(res.failed) failed, \(ByteSizeFormatter.format(res.freedBytes)) freed"
                executing = false
                // This is always the terminal step when reached, so it's the
                // one place that should surface the completion popup.
                let hadIssues = res.failed > 0
                completionAlert = CompletionAlert(
                    title: hadIssues ? "Uninstalled with Warnings" : "App Uninstalled",
                    message: hadIssues
                        ? "\(appName) was removed, but \(res.failed) leftover item(s) failed to remove. \(ByteSizeFormatter.format(res.freedBytes)) freed."
                        : "\(appName) and its leftovers were removed successfully. \(ByteSizeFormatter.format(res.freedBytes)) freed."
                )
                selectedApp = nil
            }
        }
    }
}

private struct AppRow: View {
    let app: AppInventory.AppInfo
    let onUninstall: () -> Void

    private var protected: Bool { AppInventory.isProtected(app) }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(protected ? 0.6 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if protected {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 11))
                            .background(Circle().fill(.background).frame(width: 13, height: 13))
                    }
                }
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
                    if let bucket = app.staleUseBucket, app.sizeBytes >= 500_000_000 {
                        Label(bucket, systemImage: "clock")
                            .foregroundStyle(.orange)
                    } else if let lastUsed = app.lastUsed {
                        Label("Used \(lastUsed.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                    if protected {
                        Text("Protected — cannot uninstall").foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Text(ByteSizeFormatter.format(app.sizeBytes))
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Uninstall", role: .destructive, action: onUninstall)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(protected)
        }
        .padding(.vertical, 4)
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
