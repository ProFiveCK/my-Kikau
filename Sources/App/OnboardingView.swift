import AppKit
import Core
import SwiftUI

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
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to myKikau")
                .font(.title.bold())

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
                .buttonStyle(.borderedProminent)

                Button(hasFullDiskAccess ? "Continue" : "Skip for now") {
                    onContinue()
                }
                .buttonStyle(.bordered)
            }

            Text("You can grant this later too — Status will show a reminder until it's on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 420)
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
