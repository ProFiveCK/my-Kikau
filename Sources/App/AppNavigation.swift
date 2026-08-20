import Foundation
import Features

/// Lets the menu bar HUD (a separate SwiftUI scene) tell the main window which
/// sidebar screen to jump to — e.g. "Open Clean…" from the HUD should bring the
/// main window forward already on the Clean screen, not just to whatever tab
/// was last open.
@MainActor
final class AppNavigation: ObservableObject {
    /// Which of `DuplicatesView`'s two modes to land on. A typed enum here
    /// (rather than the raw `String` this used to be) means the sender and
    /// `DuplicatesView`'s `onAppear` check can't drift apart the way
    /// `"largeFiles"` vs. `Mode.largeFiles.rawValue` ("Large Files") once did.
    enum DuplicatesMode {
        case duplicates
        case largeFiles
    }

    static let shared = AppNavigation()

    @Published var pendingSelection: ContentView.SidebarItem?
    @Published var pendingDuplicatesMode: DuplicatesMode?
    @Published var pendingProcessMode: ProcessMonitor.SortMode?

    private init() {}
}
