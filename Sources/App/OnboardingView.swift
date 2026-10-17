import AppKit
import Core
import SwiftUI
import UI

/// First-launch screen: explains why myKikau needs Full Disk Access and links
/// straight to the System Settings pane to grant it.
///
/// Shown once (gated by `myKikau.didCompleteOnboarding` in `RootView`). If the
/// user skips granting access, `StatusView` shows a small persistent reminder
/// banner instead of nagging on every launch.
struct OnboardingView: View {
    let onContinue: () -> Void

    @State private var hasFullDiskAccess = FullDiskAccessCheck.probe()

    var body: some View {
        VStack(spacing: 20) {
            AppBrandIcon(size: 88)

            Text("Welcome to myKikau")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text("""
            myKikau cleans caches, uninstalls apps along with their leftovers, and \
            inspects disk usage across your whole Mac — including other apps' \
            Library folders. macOS calls that Full Disk Access, and it can only be \
            granted by hand, in System Settings.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)

            Label(
                hasFullDiskAccess ? "Full Disk Access granted" : "Full Disk Access not granted yet",
                systemImage: hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .foregroundStyle(hasFullDiskAccess ? .green : .orange)
            .font(.subheadline)

            HStack(spacing: 12) {
                Button("Open System Settings…") {
                    openFullDiskAccessSettings()
                }
                .carePrimaryAction()

                Button(hasFullDiskAccess ? "Continue" : "Skip for now") {
                    onContinue()
                }
                .buttonStyle(.bordered)
            }

            Text("You can grant access later in System Settings. Scan coverage shows any locations that could not be checked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 420)
        .careScreen()
        .onAppear { hasFullDiskAccess = FullDiskAccessCheck.probe() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-probe when the user comes back from System Settings.
            hasFullDiskAccess = FullDiskAccessCheck.probe()
        }
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
