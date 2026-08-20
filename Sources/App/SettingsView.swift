import SwiftUI
import Core

/// The app's real Preferences window (⌘, / App menu → Settings…), via
/// SwiftUI's `Settings` scene in `myKikauApp`. Previously the only app-level
/// toggle ("Show Dock icon") lived inside the About screen, which isn't
/// where a macOS user looks for preferences — and there was no "Launch at
/// Login" option at all despite myKikau being a menu-bar-resident utility.
struct SettingsView: View {
    @AppStorage(AppStorageKey.showDockIcon) private var showDockIcon = true
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch myKikau at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Appearance") {
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, value in
                        DockIconController.apply(showDockIcon: value)
                    }
                Text("When disabled, myKikau stays in the menu bar and no longer appears in the Dock or app switcher.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = LaunchAtLoginService.isEnabled }
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
                case .failure(let error):
                    launchAtLogin = !newValue
                    launchAtLoginError = error.localizedDescription
                }
            }
        )
    }
}
