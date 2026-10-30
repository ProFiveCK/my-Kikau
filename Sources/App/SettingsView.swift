import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UI
import Core
import Features

/// The app's Preferences window (⌘, / App menu → Settings…), via SwiftUI's
/// `Settings` scene in `myKikauApp`.
///
/// Anything an administrator has set through a configuration profile
/// (`ManagedPolicy`) is shown as it is enforced, with its control disabled.
/// Everything support asks for first — version, log location, policy in
/// force, Full Disk Access — is visible here without leaving the window.
struct SettingsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case general, safety, files, advanced
        var id: Self {
            self
        }

        var label: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .safety: "Safety"
            case .files: "Files"
            case .advanced: "Advanced"
            }
        }
    }

    @State private var section: Section = .general

    private var subtitle: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        var text = String(localized: "Version \(version) (\(build))")
        if let organisation = ManagedPolicy.shared.organisationName {
            text += " · " + String(localized: "Managed by \(organisation)")
        } else if ManagedPolicy.shared.isManaged {
            text += " · " + String(localized: "Managed by your organisation")
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            CareWindowHeader("Settings", subtitle: subtitle) {
                if ManagedPolicy.shared.isManaged {
                    Label("Managed", systemImage: "building.2")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(CareTheme.lilac, in: Capsule())
                        .help("Some settings are set by a configuration profile. See Advanced for the policy in force.")
                }
            }
            Picker("Settings section", selection: $section) {
                ForEach(Section.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 22).padding(.bottom, 14)
            Group {
                switch section {
                case .general: GeneralSettings()
                case .safety: SafetySettings()
                case .files: FilesSettings()
                case .advanced: AdvancedSettings()
                }
            }.frame(maxHeight: .infinity)
        }
        // Settings has its own typography and controls. In particular, it
        // must not inherit the menu-bar footer's caption/plain-button style.
        .font(.body).controlSize(.regular).buttonStyle(.bordered)
        .careScreen()
        .frame(width: 600).frame(minHeight: 520, idealHeight: 680, maxHeight: 760)
        .background(SettingsWindowReader { SettingsPresentation.shared.register($0) })
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(AppStorageKey.showDockIcon) private var showDockIcon = true
    @AppStorage(AppStorageKey.scheduledScanIntervalHours) private var scanIntervalHours = 0
    @AppStorage(AppStorageKey.notifyReclaimableThresholdMB) private var notifyThresholdMB = 2000
    @AppStorage(AppStorageKey.didCompleteOnboarding) private var didCompleteOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var launchAtLoginError: String?
    @State private var notificationStatus: BackgroundScanScheduler.NotificationStatus?

    private var managedInterval: Int? {
        ManagedPolicy.shared.scheduledScanIntervalHours
    }

    private var effectiveInterval: Int {
        managedInterval ?? scanIntervalHours
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch myKikau at login", isOn: launchAtLoginBinding)
                    .managedBy(LaunchAtLoginService.isManaged)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, value in
                        DockIconController.apply(showDockIcon: value)
                    }
                Text("When off, myKikau stays in the menu bar and no longer appears in the Dock or app switcher.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background Scan") {
                Picker("Scan automatically", selection: managedInterval == nil ? $scanIntervalHours : .constant(managedInterval ?? 0)) {
                    Text("Never").tag(0)
                    Text("Every day").tag(24)
                    Text("Every week").tag(168)
                    if let managedInterval, ![0, 24, 168].contains(managedInterval) {
                        Text("Every \(managedInterval) hours").tag(managedInterval)
                    }
                }
                .managedBy(managedInterval != nil)

                Picker("Notify me when it finds", selection: $notifyThresholdMB) {
                    Text("1 GB or more").tag(1000)
                    Text("2 GB or more").tag(2000)
                    Text("5 GB or more").tag(5000)
                    Text("10 GB or more").tag(10000)
                }
                .disabled(effectiveInterval == 0)
                if effectiveInterval > 0, let notificationStatus, notificationStatus != .allowed {
                    HStack {
                        Label(notificationStatus.explanation, systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        if notificationStatus == .denied {
                            Button("Open Notification Settings…") {
                                BackgroundScanScheduler.openNotificationSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Text("Background Quick scans check everyday cleanup and startup items. Nothing is removed until you review it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Welcome") {
                HStack {
                    Text("First-run introduction and Full Disk Access guide")
                    Spacer()
                    Button("Show Again") {
                        didCompleteOnboarding = false
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLoginService.isEnabled }
        .task { await refreshNotificationStatus() }
        .onChange(of: scanIntervalHours) { _, hours in
            if hours > 0 {
                BackgroundScanScheduler.shared.requestNotificationPermission()
            }
            BackgroundScanScheduler.shared.reschedule()
            Task { await refreshNotificationStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationStatus() }
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await BackgroundScanScheduler.shared.notificationStatus()
    }

    /// Reverts the toggle and surfaces the error inline if `SMAppService`
    /// registration fails (e.g. running an unsigned dev build, where login
    /// item registration isn't available) rather than showing a toggle state
    /// that doesn't match what's actually registered.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                switch LaunchAtLoginService.setEnabled(newValue) {
                case .success:
                    launchAtLoginError = nil
                case let .failure(error):
                    launchAtLogin = !newValue
                    launchAtLoginError = error.localizedDescription
                }
            }
        )
    }
}

// MARK: - Safety

private struct SafetySettings: View {
    @State private var userPaths = ExclusionStore.shared.userPaths
    @State private var selection = Set<String>()
    @State private var logEnabled = OperationLog.shared.enabled
    @State private var hasFullDiskAccess = FullDiskAccessCheck.probe()
    @State private var notice: SettingsNotice?

    private var managedPaths: [String] {
        ExclusionStore.shared.managedPaths
    }

    private var logForced: Bool {
        ManagedPolicy.shared.forceOperationLog
    }

    var body: some View {
        Form {
            Section("Access") {
                HStack {
                    Label(
                        hasFullDiskAccess ? "Full Disk Access granted" : "Full Disk Access not granted",
                        systemImage: hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(hasFullDiskAccess ? .green : .orange)
                    Spacer()
                    if !hasFullDiskAccess {
                        Button("Open System Settings…") { FullDiskAccessCheck.openSystemSettings() }
                    }
                }
                Text(
                    hasFullDiskAccess
                        ? "myKikau can see other apps' caches and leftovers. Scan coverage lists anything that still can't be read."
                        : "Without it, other apps' caches and leftovers are invisible to scans. Grant it under Privacy & Security → Full Disk Access."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                List(selection: $selection) {
                    ForEach(managedPaths, id: \.self) { path in
                        Label(path, systemImage: "building.2")
                            .foregroundStyle(.secondary)
                            .help("Set by your organisation")
                    }
                    ForEach(userPaths, id: \.self) { path in
                        Label(path, systemImage: "folder")
                            .tag(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                    if managedPaths.isEmpty, userPaths.isEmpty {
                        Text("Nothing excluded")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120)
                .onDeleteCommand(perform: removeSelected)
                HStack {
                    Button("Add…") { addExclusions() }
                    Button("Remove", action: removeSelected)
                        .disabled(selection.isEmpty)
                    Spacer()
                }
            } header: {
                Text("Never Remove")
            } footer: {
                Text(
                    "Files and folders listed here — and everything inside them — are skipped by every scan and can never be removed "
                        + "by myKikau. System folders, keychains, mail and security software are always protected."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Operation Log") {
                Toggle("Record what myKikau removes", isOn: Binding(
                    get: { logForced || logEnabled },
                    set: { value in
                        logEnabled = value
                        OperationLog.shared.enabled = value
                    }
                ))
                .managedBy(logForced)
                LabeledContent("Location") {
                    Text(OperationLog.shared.fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([OperationLog.shared.fileURL])
                    }
                    Button("Export…") { export() }
                    Button("Check Integrity") { verify() }
                    Spacer()
                }
                Text(
                    "The log powers History, Put Back and “freed to date”. It stays on this Mac; each entry is also written "
                        + "to the unified log (subsystem com.profiveck.myKikau, category audit) for log collection."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccessCheck.probe()
        }
        .settingsNotice($notice)
    }

    private func addExclusions() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = "Never Remove"
        guard panel.runModal() == .OK else { return }
        userPaths.append(contentsOf: panel.urls.map(\.path).filter { !userPaths.contains($0) })
        save()
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        userPaths.removeAll { selection.contains($0) }
        selection = []
        save()
    }

    private func save() {
        ExclusionStore.shared.setUserPaths(userPaths)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "myKikau-operations.csv"
        panel.allowedContentTypes = [.commaSeparatedText, .json]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format: OperationLog.ExportFormat = url.pathExtension.lowercased() == "csv" ? .csv : .jsonl
        do {
            try OperationLog.shared.export(to: url, format: format)
            notice = SettingsNotice(title: "Log Exported", message: "Written to \(url.path).")
        } catch {
            notice = SettingsNotice(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func verify() {
        Task {
            let status = await Task.detached { OperationLog.shared.verifyChain() }.value
            if status.isIntact {
                notice = SettingsNotice(title: "Log Is Intact", message: "\(status.verified.formatted()) entries verified against the entry before them.")
            } else {
                notice = SettingsNotice(title: "Log Integrity Problem", message: "The log was edited or entries were removed outside myKikau. History → Log → Check Log Integrity has the details.")
            }
        }
    }
}

// MARK: - Files

private struct FilesSettings: View {
    @AppStorage(AppStorageKey.largeFileThresholdMB) private var thresholdMB = DuplicateFinder.defaultLargeFileThresholdMB
    @State private var extraFolders = UserDefaults.standard.stringArray(forKey: AppStorageKey.fileScanFolders) ?? []
    @State private var selection = Set<String>()

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(DuplicateFinder.defaultScanPaths, id: \.self) { name in
                        Label(name, systemImage: "folder")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(extraFolders, id: \.self) { path in
                        Label(path, systemImage: "folder.badge.plus")
                            .tag(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
                .frame(minHeight: 150)
                .onDeleteCommand(perform: removeSelected)
                HStack {
                    Button("Add Folder…") { addFolders() }
                    Button("Remove", action: removeSelected)
                        .disabled(selection.isEmpty)
                    Spacer()
                }
            } header: {
                Text("Folders Scanned for Duplicates and Large Files")
            } footer: {
                Text("The standard folders are always included. Folders you add are scanned alongside them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("List files larger than", selection: $thresholdMB) {
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        extraFolders.append(contentsOf: panel.urls.map(\.path).filter { !extraFolders.contains($0) })
        save()
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        extraFolders.removeAll { selection.contains($0) }
        selection = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(extraFolders, forKey: AppStorageKey.fileScanFolders)
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @AppStorage(AppStorageKey.developerToolsEnabled) private var developerTools = false
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @State private var helperStatus = PrivilegedHelperClient.status
    @State private var helperError: String?
    @State private var notice: SettingsNotice?

    private var policy: ManagedPolicy {
        ManagedPolicy.shared
    }

    private var purgeDisabled: Bool {
        policy.isFeatureDisabled("purge")
    }

    private var networkDisabled: Bool {
        policy.isFeatureDisabled("network")
    }

    private var advancedToolsDescription: LocalizedStringKey {
        switch (purgeDisabled, networkDisabled) {
        case (true, true):
            "Network and Project Purge are turned off by your organisation."
        case (true, false):
            "Adds Network (addresses, DNS and connection tools) to the sidebar. Project Purge is turned off by your organisation."
        case (false, true):
            "Adds Project Purge (node_modules, build output and virtual environments in your project folders) to the sidebar. Network is turned off by your organisation."
        case (false, false):
            "Adds Network (addresses, DNS and connection tools) and Project Purge (node_modules, build output and virtual environments in your project folders) to the sidebar."
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Advanced tools", isOn: $developerTools)
                    .managedBy(purgeDisabled && networkDisabled)
                Text(advancedToolsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if helperStatus != .notBundled {
                Section {
                    LabeledContent("Status", value: helperStatusText)
                    HStack {
                        switch helperStatus {
                        case .notInstalled:
                            Button("Install Helper…") { installHelper() }
                                .disabled(policy.disablePrivilegedTools)
                        case .requiresApproval:
                            Button("Open Login Items Settings…") { PrivilegedHelperClient.openApprovalSettings() }
                            Button("Remove Helper") { removeHelper() }
                        case .enabled:
                            Button("Remove Helper") { removeHelper() }
                        case .notBundled:
                            EmptyView()
                        }
                        Spacer()
                    }
                    if let helperError {
                        Text(helperError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if policy.disablePrivilegedTools {
                        ManagedNote("Administrator actions are turned off by your organisation; an installed helper is not used.")
                    }
                } header: {
                    Text("Administrator Helper")
                } footer: {
                    Text(
                        "Optional. Lets Uninstall remove apps that were installed for all users, and their system-wide background "
                            + "items. It asks for an administrator password each time, only ever moves those items to your Trash, "
                            + "and does nothing else."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                if updaterViewModel.updatesAvailable {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updaterViewModel.automaticallyChecksForUpdates },
                        set: { updaterViewModel.automaticallyChecksForUpdates = $0 }
                    ))
                    // Also here because, with the Dock icon hidden, the app
                    // menu's "Check for Updates…" isn't visible.
                    HStack {
                        Text("Check for a newer version now")
                        Spacer()
                        Button("Check Now") { updaterViewModel.checkForUpdates() }
                            .disabled(!updaterViewModel.canCheckForUpdates)
                    }
                } else {
                    ManagedNote("Updates are deployed by your organisation. The app never contacts the update server.")
                }
            }

            Section("Support") {
                if let contact = policy.supportContact {
                    HStack {
                        Text("Help from \(policy.organisationName ?? String(localized: "your organisation"))")
                        Spacer()
                        SupportContactButton(contact: contact)
                    }
                }
                HStack {
                    Text("Settings and counts for a support request. No file names or paths are included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Diagnostics…") { saveDiagnostics() }
                }
            }

            if policy.isManaged {
                Section("Managed by Your Organisation") {
                    if let organisation = policy.organisationName {
                        LabeledContent("Organisation", value: organisation)
                    }
                    if !policy.disabledFeatures.isEmpty {
                        LabeledContent("Disabled features", value: policy.disabledFeatures.sorted().joined(separator: ", "))
                    }
                    if policy.disablePrivilegedTools {
                        LabeledContent("Administrator actions", value: "Disabled")
                    }
                    if policy.disableAutomaticUpdates {
                        LabeledContent("Updates", value: "Deployed by the organisation")
                    }
                    if policy.disableNetworkLookups {
                        LabeledContent("Update and public IP lookups", value: "Disabled")
                    }
                    if policy.forceOperationLog {
                        LabeledContent("Operation log", value: "Always on")
                    }
                    if let hours = policy.scheduledScanIntervalHours {
                        LabeledContent("Background scan", value: "Every \(hours) hours")
                    }
                    if let launch = policy.launchAtLogin {
                        LabeledContent("Launch at login", value: launch ? "On" : "Off")
                    }
                    if !policy.protectedPaths.isEmpty {
                        DisclosureGroup("Protected paths (\(policy.protectedPaths.count))") {
                            ForEach(policy.protectedPaths, id: \.self) { path in
                                Text(path).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(path)
                            }
                        }
                    }
                    if !policy.protectedBundlePrefixes.isEmpty {
                        DisclosureGroup("Protected software (\(policy.protectedBundlePrefixes.count))") {
                            ForEach(policy.protectedBundlePrefixes, id: \.self) { prefix in
                                Text(prefix).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings after approving the helper.
            helperStatus = PrivilegedHelperClient.status
        }
        .settingsNotice($notice)
    }

    private var helperStatusText: String {
        switch helperStatus {
        case .notBundled: String(localized: "Not included in this build")
        case .notInstalled: String(localized: "Not installed")
        case .requiresApproval: String(localized: "Waiting for approval in System Settings")
        case .enabled: String(localized: "Installed")
        }
    }

    private func installHelper() {
        do {
            try PrivilegedHelperClient.install()
            helperError = nil
        } catch {
            helperError = error.localizedDescription
        }
        helperStatus = PrivilegedHelperClient.status
        if helperStatus == .requiresApproval {
            PrivilegedHelperClient.openApprovalSettings()
        }
    }

    private func removeHelper() {
        Task {
            do {
                try await PrivilegedHelperClient.uninstall()
                helperError = nil
            } catch {
                helperError = error.localizedDescription
            }
            helperStatus = PrivilegedHelperClient.status
        }
    }

    private func saveDiagnostics() {
        Task {
            switch await DiagnosticsExport.save() {
            case .cancelled: break
            case .saved: break
            case let .failed(message): notice = SettingsNotice(title: "Couldn't Save Diagnostics", message: message)
            }
        }
    }
}

/// Opens an organisation's support contact: a web address, an email address
/// (with or without `mailto:`), or, failing both, shows the text to copy.
struct SupportContactButton: View {
    let contact: String

    private var url: URL? {
        if let url = URL(string: contact), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            return url
        }
        if contact.contains("@"), !contact.contains(" "), let url = URL(string: "mailto:" + contact) {
            return url
        }
        return nil
    }

    var body: some View {
        if let url {
            Button(url.scheme == "mailto" ? "Email Support" : "Open Support Page") { NSWorkspace.shared.open(url) }
                .help(contact)
        } else {
            Text(contact).textSelection(.enabled).foregroundStyle(.secondary)
        }
    }
}

/// Saves the diagnostics report through a save panel and reveals the file,
/// so the person knows exactly what to attach to their support request.
@MainActor
enum DiagnosticsExport {
    enum Outcome {
        case saved(URL)
        case cancelled
        case failed(String)
    }

    static func save() async -> Outcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "myKikau-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let result = await Task.detached { () -> String? in
            let report = DiagnosticsReport.generate(appVersion: version, build: build)
            do {
                try Data(report.utf8).write(to: url, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let result {
            return .failed(result)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return .saved(url)
    }
}

struct SettingsNotice: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let message: String
}

private extension View {
    func settingsNotice(_ notice: Binding<SettingsNotice?>) -> some View {
        alert(
            notice.wrappedValue?.title ?? "",
            isPresented: Binding(get: { notice.wrappedValue != nil }, set: {
                if !$0 {
                    notice.wrappedValue = nil
                }
            }),
            presenting: notice.wrappedValue
        ) { _ in
            Button("OK") { notice.wrappedValue = nil }
        } message: { current in
            Text(current.message)
        }
    }
}
