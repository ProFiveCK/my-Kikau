import SwiftUI
import Core
import Features
import UI

struct UninstallView: View {
    @State private var apps: [AppInventory.AppInfo] = []
    @State private var scanning = false
    @State private var selectedApp: AppInventory.AppInfo?
    @State private var appPlan: SafeFileDeleter.Plan?
    @State private var leftoverPlan: SafeFileDeleter.Plan?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
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
                        .onTapGesture {
                            selectedApp = app
                            let plans = LeftoverFinder.uninstallPlan(app: app)
                            appPlan = plans.appPlan
                            leftoverPlan = plans.leftoverPlan
                        }
                }
            }
        }
        .sheet(item: $appPlan) { plan in
            PlanReviewView(plan: plan, title: "Uninstall \(selectedApp?.name ?? "")") { _ in
                appPlan = nil
            }
        }
    }
}

private struct AppRow: View {
    let app: AppInventory.AppInfo

    var body: some View {
        HStack {
            Image(systemName: AppInventory.isProtected(app) ? "exclamationmark.shield" : "app")
                .foregroundStyle(AppInventory.isProtected(app) ? .red : .accentColor)
            VStack(alignment: .leading) {
                Text(app.name)
                if let version = app.version {
                    Text(version).font(.caption).foregroundStyle(.secondary)
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