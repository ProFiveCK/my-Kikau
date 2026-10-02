import AppKit
import SwiftUI
import Core
import Features

/// The app's Preferences window (⌘, / App menu → Settings…), via SwiftUI's
/// `Settings` scene in `myKikauApp`.
///
/// Anything an administrator has set through a configuration profile
/// (`ManagedPolicy`) is shown as it is enforced, with its control disabled.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettings()
                .tabItem { Label("Safety", systemImage: "lock.shield") }
            FilesSettings()
                .tabItem { Label("Files", systemImage: "doc.on.doc") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
    }
}

/// One line explaining that a setting is controlled by a profile.
private struct ManagedNote: View {
    var body: some View {
        Label("Set by your organisation", systemImage: "building.2")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(AppStorageKey.showDockIcon) private var showDockIcon = true
    @AppStorage(AppStorageKey.scheduledScanIntervalHours) private var scanIntervalHours = 0
    @AppStorage(AppStorageKey.notifyReclaimableThresholdMB) private var notifyThresholdMB = 2000
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var launchAtLoginError: String?

    private var managedInterval: Int? {
        ManagedPolicy.shared.scheduledScanIntervalHours
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch myKikau at login", isOn: launchAtLoginBinding)
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
                .disabled(managedInterval != nil)
                if managedInterval != nil {
                    ManagedNote()
                }

                Picker("Notify me when it finds", selection: $notifyThresholdMB) {
                    Text("1 GB or more").tag(1000)
                    Text("2 GB or more").tag(2000)
                    Text("5 GB or more").tag(5000)
                    Text("10 GB or more").tag(10000)
                }
                .disabled((managedInterval ?? scanIntervalHours) == 0)
                Text("A background scan only measures. Nothing is removed until you review it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = LaunchAtLoginService.isEnabled }
        .onChange(of: scanIntervalHours) { _, hours in
            if hours > 0 {
                BackgroundScanScheduler.shared.requestNotificationPermission()
            }
            BackgroundScanScheduler.shared.reschedule()
        }
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
    @State private var selection: String?
    @State private var logEnabled = OperationLog.shared.enabled

    private var managedPaths: [String] {
        ExclusionStore.shared.managedPaths
    }

    private var logForced: Bool {
        ManagedPolicy.shared.forceOperationLog
    }

    var body: some View {
        Form {
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
                HStack {
                    Button("Add…") { addExclusions() }
                    Button("Remove") {
                        userPaths.removeAll { $0 == selection }
                        selection = nil
                        save()
                    }
                    .disabled(selection == nil)
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
                .disabled(logForced)
                if logForced {
                    ManagedNote()
                }
                Text("The log powers History, Put Back and “freed to date”. It stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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

    private func save() {
        ExclusionStore.shared.setUserPaths(userPaths)
    }
}

// MARK: - Files

private struct FilesSettings: View {
    @AppStorage(AppStorageKey.largeFileThresholdMB) private var thresholdMB = DuplicateFinder.defaultLargeFileThresholdMB
    @State private var extraFolders = UserDefaults.standard.stringArray(forKey: AppStorageKey.fileScanFolders) ?? []
    @State private var selection: String?

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
                HStack {
                    Button("Add Folder…") { addFolders() }
                    Button("Remove") {
                        extraFolders.removeAll { $0 == selection }
                        selection = nil
                        save()
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
            } header: {
                Text("Folders Scanned for Duplicates and Large Files")
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
        .fixedSize(horizontal: false, vertical: true)
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

    private func save() {
        UserDefaults.standard.set(extraFolders, forKey: AppStorageKey.fileScanFolders)
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @AppStorage(AppStorageKey.developerToolsEnabled) private var developerTools = false
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel

    private var policy: ManagedPolicy {
        ManagedPolicy.shared
    }

    var body: some View {
        Form {
            Section {
                Toggle("Developer tools", isOn: $developerTools)
                    .disabled(policy.isFeatureDisabled("purge"))
                Text("Adds Project Purge to the sidebar: finds node_modules, build output and virtual environments in your project folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if policy.isFeatureDisabled("purge") {
                    ManagedNote()
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updaterViewModel.automaticallyChecksForUpdates },
                    set: { updaterViewModel.automaticallyChecksForUpdates = $0 }
                ))
                .disabled(policy.disableAutomaticUpdates)
                if policy.disableAutomaticUpdates {
                    ManagedNote()
                }
            }

            if policy.isManaged {
                Section("Managed by Your Organisation") {
                    if !policy.disabledFeatures.isEmpty {
                        LabeledContent("Disabled features", value: policy.disabledFeatures.sorted().joined(separator: ", "))
                    }
                    if policy.disablePrivilegedTools {
                        LabeledContent("Administrator actions", value: "Disabled")
                    }
                    if policy.forceOperationLog {
                        LabeledContent("Operation log", value: "Always on")
                    }
                    if !policy.protectedPaths.isEmpty {
                        LabeledContent("Protected paths", value: "\(policy.protectedPaths.count)")
                    }
                    if !policy.protectedBundlePrefixes.isEmpty {
                        LabeledContent("Protected software", value: "\(policy.protectedBundlePrefixes.count) prefix(es)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
