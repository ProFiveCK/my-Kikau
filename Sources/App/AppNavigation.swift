import Foundation
import Features

/// Lets the menu bar HUD (a separate SwiftUI scene) tell the main window which
/// sidebar screen to jump to — e.g. "Open Clean…" from the HUD should bring the
/// main window forward already on the Clean screen, not just to whatever tab
/// was last open.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    @Published var pendingSelection: ContentView.SidebarItem?
    @Published var pendingDuplicatesMode: String?
    @Published var pendingProcessMode: ProcessMonitor.SortMode?

    private init() {}
}
