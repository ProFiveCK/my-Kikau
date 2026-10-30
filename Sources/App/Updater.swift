import Combine
import Core
import Sparkle
import SwiftUI

/// Thin SwiftUI wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Starts the updater on launch (Sparkle reads `SUFeedURL` / `SUPublicEDKey` /
/// `SUEnableAutomaticChecks` / `SUScheduledCheckInterval` from Info.plist).
///
/// When an administrator sets `DisableAutomaticUpdates`, the updater is never
/// started: no background checks, no feed requests, and every "Check for
/// Updates…" control is hidden. The organisation deploys updates itself.
@MainActor
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false
    /// False when policy has switched the updater off; views hide their
    /// update controls instead of showing them disabled.
    let updatesAvailable: Bool

    init() {
        let disabled = ManagedPolicy.shared.disableAutomaticUpdates
        updatesAvailable = !disabled
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !disabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        guard !disabled else { return }
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        guard updatesAvailable else { return }
        updaterController.updater.checkForUpdates()
    }
}

/// "Check for Updates…" menu command — insert into the app menu via `.commands`.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        if updaterViewModel.updatesAvailable {
            Button("Check for Updates…") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)
        }
    }
}
