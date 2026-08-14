import AppKit
import Core
import SwiftUI

/// Replaces the old "History" sidebar destination — a raw operation log
/// wasn't a useful screen of its own. This shows what an About screen
/// actually needs (version, updates, source, license), and the operation
/// log is still one click away via "Reveal Log File" rather than gone.
struct AboutView: View {
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @AppStorage(AppStorageKey.showDockIcon) private var showDockIcon = true
    @State private var totalFreed: Int64 = 0
    @State private var operationCount: Int = 0

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
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
                }

                InfoCard(title: "This Install") {
                    InfoRow(label: "Trash-recoverable operations logged", value: "\(operationCount)")
                    InfoRow(label: "Total freed to date", value: ByteSizeFormatter.format(totalFreed))
                    HStack {
                        Text("Log file")
                            .font(.subheadline)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([OperationLog.shared.fileURL])
                        }
                        .font(.caption)
                    }
                }

                InfoCard(title: "Appearance") {
                    Toggle("Show Dock icon", isOn: $showDockIcon)
                        .onChange(of: showDockIcon) { _, value in
                            DockIconController.apply(showDockIcon: value)
                        }
                    Text("When disabled, myKikau stays in the menu bar and no longer appears in the Dock or app switcher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                InfoCard(title: "About") {
                    InfoRow(label: "Publisher", value: "Project Five")
                    InfoRow(label: "License", value: "GPL-3.0")
                    HStack {
                        Text("Built on")
                            .font(.subheadline)
                        Spacer()
                        Button("Mole (GPL-3.0)") {
                            if let url = URL(string: "https://github.com/tw93/Mole") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.caption)
                    }
                    Text("Logic reimplemented natively in Swift, informed by Mole (Go + Bash CLI). Mole is credited as the source; myKikau is independent and released under the same license.")
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
            totalFreed = OperationLog.shared.totalFreed()
            operationCount = OperationLog.shared.recent(limit: 10_000).count
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
