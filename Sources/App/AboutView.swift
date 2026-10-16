import AppKit
import Core
import Features
import SwiftUI

/// Replaces the old "History" sidebar destination — a raw operation log
/// wasn't a useful screen of its own. This shows what an About screen
/// actually needs (version, updates, source, license), and the operation
/// log is still one click away via "Reveal Log File" rather than gone.
struct AboutView: View {
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @State private var totalFreed: Int64 = 0
    @State private var operationCount: Int = 0

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private func saveDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "myKikau-diagnostics.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = shortVersion
        let build = buildNumber
        Task.detached {
            let report = DiagnosticsReport.generate(appVersion: version, build: build)
            try? Data(report.utf8).write(to: url, options: .atomic)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("myKikau")
                        .font(.title.bold())
                    Text("Version \(shortVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("A native Swift macOS cleanup, uninstaller, and maintenance app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .padding(.top, 24)

                HStack(spacing: 12) {
                    Button {
                        if let url = URL(string: "https://www.projectfive.co.ck/apps/mykikau/") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Product Page", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        updaterViewModel.checkForUpdates()
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updaterViewModel.canCheckForUpdates)

                    Button {
                        if let url = URL(string: "https://github.com/ProFiveCK/my-Kikau") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.bordered)

                    // Dock icon and Launch at Login used to live in an
                    // "Appearance" card here — moved to a real Settings
                    // window (⌘,), which is where a macOS user actually
                    // looks for them. This link keeps them one click away
                    // for anyone who lands on About first.
                    SettingsLink {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }

                InfoCard(title: "This Install") {
                    InfoRow(label: "Operations logged", value: "\(operationCount)")
                    InfoRow(label: "Permanently removed", value: ByteSizeFormatter.format(totalFreed))
                    HStack {
                        Text("Activity")
                            .font(.subheadline)
                        Spacer()
                        Button("Open History") {
                            AppNavigation.shared.pendingSelection = .history
                        }
                        .font(.caption)
                    }
                    HStack {
                        Text("Support")
                            .font(.subheadline)
                        Spacer()
                        Button("Save Diagnostics…") { saveDiagnostics() }
                            .font(.caption)
                            .help("Saves app settings and counts for a support request. No file names or paths are included.")
                    }
                }

                InfoCard(title: "About") {
                    InfoRow(label: "Publisher", value: "Project Five")
                    InfoRow(label: "License", value: "GPL-3.0")
                    Text("Built from scratch in native Swift for macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("© 2026 Project Five. Distributed directly, not through the Mac App Store.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            Task {
                let totals = await Task.detached { OperationLog.shared.totals() }.value
                totalFreed = totals.freedBytes
                operationCount = totals.operations
            }
        }
    }
}

private struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
