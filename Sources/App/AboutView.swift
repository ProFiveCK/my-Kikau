import AppKit
import Core
import Features
import SwiftUI
import UI

/// The About window: version, updates, source and licence, plus what a
/// support request needs first (log location, policy, access, helper).
struct AboutView: View {
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var totalFreed: Int64 = 0
    @State private var operationCount: Int = 0
    @State private var notice: SettingsNotice?

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private var policy: ManagedPolicy {
        ManagedPolicy.shared
    }

    private var helperStatus: String {
        switch PrivilegedHelperClient.status {
        case .notBundled: String(localized: "Not included")
        case .notInstalled: String(localized: "Not installed")
        case .requiresApproval: String(localized: "Waiting for approval")
        case .enabled: policy.disablePrivilegedTools ? String(localized: "Installed, disabled by policy") : String(localized: "Installed")
        }
    }

    private func saveDiagnostics() {
        Task {
            if case let .failed(message) = await DiagnosticsExport.save() {
                notice = SettingsNotice(title: "Couldn't Save Diagnostics", message: message)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    AppBrandIcon(size: 88)
                    Text("myKikau")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("Version \(shortVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("A native Swift macOS cleanup, uninstaller, and maintenance app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    if let organisation = policy.organisationName {
                        Label("Managed by \(organisation)", systemImage: "building.2")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(CareTheme.panel.opacity(0.7), in: Capsule())
                    } else if policy.isManaged {
                        Label("Managed by your organisation", systemImage: "building.2")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(CareTheme.panel.opacity(0.7), in: Capsule())
                    }
                }
                .padding(28).frame(maxWidth: .infinity)
                .background(
                    LinearGradient(colors: [CareTheme.lilac, CareTheme.pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22)
                )

                HStack(spacing: 12) {
                    Button {
                        if let url = URL(string: "https://www.projectfive.co.ck/apps/") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Product Page", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)

                    if updaterViewModel.updatesAvailable {
                        Button {
                            updaterViewModel.checkForUpdates()
                        } label: {
                            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .carePrimaryAction()
                        .disabled(!updaterViewModel.canCheckForUpdates)
                    }

                    Button {
                        if let url = URL(string: "https://github.com/ProFiveCK/my-Kikau") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.bordered)

                    AppSettingsButton {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }

                if let contact = policy.supportContact {
                    InfoCard(title: "Support") {
                        HStack {
                            Text(policy.organisationName.map { String(localized: "Help from \($0)") } ?? String(localized: "Help from your organisation"))
                                .font(.subheadline)
                            Spacer()
                            SupportContactButton(contact: contact)
                                .font(.caption)
                        }
                    }
                }

                InfoCard(title: "This Install") {
                    InfoRow(label: "Operations logged", value: "\(operationCount)")
                    InfoRow(label: "Permanently removed", value: ByteSizeFormatter.format(totalFreed))
                    InfoRow(label: "Full Disk Access", value: FullDiskAccessCheck.probe() ? String(localized: "Granted") : String(localized: "Not granted"))
                    InfoRow(label: "Administrator helper", value: helperStatus)
                    InfoRow(label: "Managed by a profile", value: policy.isManaged ? String(localized: "Yes") : String(localized: "No"))
                    InfoRow(label: "Operation log", value: OperationLog.shared.fileURL.path)
                    HStack {
                        Text("Activity")
                            .font(.subheadline)
                        Spacer()
                        Button("Open History") {
                            AppNavigation.shared.pendingSelection = .history
                            openWindow(id: "main")
                        }
                        .font(.caption)
                    }
                    HStack {
                        Text("Support request")
                            .font(.subheadline)
                        Spacer()
                        Button("Save Diagnostics…") { saveDiagnostics() }
                            .font(.caption)
                            .help("Saves app settings and counts for a support request, then shows the file. No file names or paths from your disk are included.")
                    }
                }

                InfoCard(title: "About") {
                    InfoRow(label: "Publisher", value: "Project Five")
                    InfoRow(label: "License", value: "GPL-3.0")
                    Text("Built from scratch in native Swift for macOS. Nothing is sent anywhere: see PRIVACY.md in the source for what the app reads and which hosts it can contact.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("© 2026 Project Five. Distributed directly, not through the Mac App Store.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
            .padding(22)
            .frame(maxWidth: 740)
            .frame(maxWidth: .infinity)
        }
        .careScreen()
        .alert(
            notice?.title ?? "",
            isPresented: Binding(get: { notice != nil }, set: {
                if !$0 {
                    notice = nil
                }
            }),
            presenting: notice
        ) { _ in
            Button("OK") { notice = nil }
        } message: { current in
            Text(current.message)
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
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 16)
    }
}

private struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// App menu → About myKikau: opens the About window.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About myKikau") { openWindow(id: "about") }
    }
}
