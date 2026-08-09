import AppKit
import SwiftUI
import Core
import Features
import UI

/// Main app entry point. Window + menu bar HUD.
@main
struct myKikauApp: App {
    @StateObject private var updaterViewModel = UpdaterViewModel()
    @AppStorage("myKikau.showDockIcon") private var showDockIcon = true

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .frame(minWidth: 800, minHeight: 500)
                .environmentObject(updaterViewModel)
                .onAppear { DockIconController.apply(showDockIcon: showDockIcon) }
                .onChange(of: showDockIcon) { _, value in
                    DockIconController.apply(showDockIcon: value)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updaterViewModel: updaterViewModel)
            }
        }

        MenuBarExtra {
            HUDView()
        } label: {
            Image(nsImage: DockIconController.menuBarImage())
        }
        .menuBarExtraStyle(.window)
    }
}

enum DockIconController {
    static func apply(showDockIcon: Bool) {
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    static func menuBarImage() -> NSImage {
        let source = NSImage(named: "AppIcon")
            ?? NSApplication.shared.applicationIconImage
            ?? NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "myKikau")
            ?? NSImage()
        let image = source.copy() as? NSImage ?? source
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

/// Shows the first-launch onboarding once, then the real app.
struct RootView: View {
    @AppStorage("myKikau.didCompleteOnboarding") private var didCompleteOnboarding = false

    var body: some View {
        if didCompleteOnboarding {
            ContentView()
        } else {
            OnboardingView(onContinue: { didCompleteOnboarding = true })
        }
    }
}

/// Main window with sidebar navigation.
struct ContentView: View {
    enum SidebarItem: String, CaseIterable, Identifiable {
        case status, clean, uninstall, analyze, duplicates, optimize, purge, history, about
        var id: String { rawValue }

        /// Explicit display strings rather than `rawValue.capitalized` — the
        /// case names are American-spelled internal identifiers ("analyze",
        /// "optimize"), but the app is NZ/AU-facing, so what's actually shown
        /// uses "Analyse"/"Optimise".
        var label: String {
            switch self {
            case .status: "Status"
            case .clean: "Clean"
            case .uninstall: "Uninstall"
            case .analyze: "Analyse"
            case .duplicates: "Duplicates"
            case .optimize: "Optimise"
            case .purge: "Purge"
            case .history: "History"
            case .about: "About"
            }
        }

        /// Sidebar items shown to the user. Purge is pulled from this release
        /// (see docs/IMPLEMENTATION_PLAN.md) but the case, its view, and its
        /// scanner are left intact to bring back later — just excluded here.
        /// History is replaced by About (a raw operation log wasn't useful as
        /// its own sidebar destination) — the operation log itself still
        /// exists and is reachable from About via "Reveal Log File".
        static var visibleCases: [SidebarItem] {
            allCases.filter { $0 != .purge && $0 != .history }
        }

        var icon: String {
            switch self {
            case .status: "heart.text.square"
            case .clean: "internaldrive"
            case .uninstall: "app.dashed"
            case .analyze: "chart.bar.doc.horizontal"
            case .duplicates: "doc.on.doc"
            case .optimize: "wrench.and.screwdriver"
            case .purge: "hammer"
            case .history: "clock.arrow.circlepath"
            case .about: "info.circle"
            }
        }

        /// One accent color per module, shared between the Status dashboard's
        /// Quick Actions cards and each screen's own header/buttons, so landing
        /// on a screen from the dashboard feels like the same place.
        var tint: Color {
            switch self {
            case .status: .accentColor
            case .clean: .blue
            case .uninstall: .purple
            case .analyze: .teal
            case .duplicates: .pink
            case .optimize: .orange
            case .purge: .brown
            case .history: .secondary
            case .about: .secondary
            }
        }
    }

    // Status is the landing screen — it acts as the dashboard/hub that
    // launches every other feature.
    @State private var selection: SidebarItem? = .status
    @ObservedObject private var navigation = AppNavigation.shared

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.visibleCases, selection: $selection) { item in
                SidebarRow(item: item, selected: selection == item)
                    .tag(item)
            }
            .navigationTitle("myKikau")
            .frame(minWidth: 180)
        } detail: {
            switch selection {
            case .status: StatusView(onNavigate: { selection = $0 })
            case .clean: CleanView()
            case .uninstall: UninstallView()
            case .analyze: AnalyzeView()
            case .duplicates: DuplicatesView()
            case .optimize: OptimizeView()
            case .about: AboutView()
            // .purge and .history intentionally omitted — both pulled from the
            // sidebar (see SidebarItem.visibleCases); fall through to `default`
            // below if ever reached (e.g. stale @AppStorage selection from a
            // previous build). Their views/data still exist, just unrouted.
            default: StatusView(onNavigate: { selection = $0 })
            }
        }
        // Picked up when the menu bar HUD requests a specific screen (e.g. "Open Clean…").
        .onReceive(navigation.$pendingSelection) { pending in
            guard let pending else { return }
            selection = pending
            navigation.pendingSelection = nil
        }
    }
}

private struct SidebarRow: View {
    let item: ContentView.SidebarItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(item.tint.opacity(selected ? 0.22 : 0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            Text(item.label)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}
