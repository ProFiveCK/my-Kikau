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

    private let tint = ContentView.SidebarItem.uninstall.tint

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: ContentView.SidebarItem.uninstall.icon)
                    .foregroundStyle(tint)
                Text("Uninstaller").font(.title2).bold()
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

            if apps.isEmpty && !scanning {
                ContentUnavailableView(
                    "No Apps Scanned",
                    systemImage: "app.dashed",
                    description: Text("Click Scan Apps to list installed applications and find their leftovers.")
                )
            } else {
                List(apps) { app in
                    AppRow(app: app)
                        .contentShape(Rectangle())
                        .opacity(AppInventory.isProtected(app) ? 0.5 : 1)
                        .onTapGesture {
                            guard !AppInventory.isProtected(app) else { return }
                            selectApp(app)
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
                    executionSummary = "Dry-run: " + (summary.isEmpty ? "no teardown actions" : summary.joined(separator: ", "))
                    executing = false
                }
                return
            }

            let deleter = SafeFileDeleter.shared
            _ = deleter.execute(plan, mode: .trash, dryRun: false, action: "uninstall.app")
            await MainActor.run {
                teardownResult = teardown
                executionSummary = summary.isEmpty ? "App removed; no teardown actions" : summary.joined(separator: ", ")
                executing = false
                // Present the leftover plan next.
                if let lp = leftoverPlan, !lp.isEmpty {
                    leftoverPlan = lp
                }
            }
        }
    }

    private func handleLeftoverPlanConfirm(dryRun: Bool) {
        guard let plan = leftoverPlan else {
            leftoverPlan = nil
            return
        }
        leftoverPlan = nil
        if dryRun {
            executionSummary = (executionSummary ?? "") + " · Leftover dry-run only"
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
                selectedApp = nil
            }
        }
    }
}

private struct AppRow: View {
    let app: AppInventory.AppInfo

    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(AppInventory.isProtected(app) ? 0.6 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if AppInventory.isProtected(app) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 11))
                            .background(Circle().fill(.background).frame(width: 13, height: 13))
                    }
                }
            VStack(alignment: .leading) {
                Text(app.name)
                if let version = app.version {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
                if AppInventory.isProtected(app) {
                    Text("Protected — cannot uninstall").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Text(ByteSizeFormatter.format(app.sizeBytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
