import Combine
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
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
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
