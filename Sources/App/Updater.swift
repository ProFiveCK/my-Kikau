import Combine
import Core
import Sparkle
import SwiftUI

/// Thin SwiftUI wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Starts the updater on launch (Sparkle reads `SUFeedURL` / `SUPublicEDKey` /
/// `SUEnableAutomaticChecks` / `SUScheduledCheckInterval` from Info.plist — see the
/// placeholders there, which must be filled in with real values before shipping).
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // An administrator can turn off background update checks (the app is
        // then updated by the organisation's own deployment tooling). Manual
        // "Check for Updates…" still works.
        if ManagedPolicy.shared.disableAutomaticUpdates {
            updaterController.updater.automaticallyChecksForUpdates = false
        }
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
        updaterController.updater.checkForUpdates()
    }
}

/// "Check for Updates…" menu command — insert into the app menu via `.commands`.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…") {
            updaterViewModel.checkForUpdates()
        }
        .disabled(!updaterViewModel.canCheckForUpdates)
    }
}
