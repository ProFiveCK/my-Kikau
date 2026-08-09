import SwiftUI
import Core
import Features
import UI

/// Main app entry point. Window + menu bar HUD.
@main
struct myKikauApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            HUDView()
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Main window with sidebar navigation.
struct ContentView: View {
    enum SidebarItem: String, CaseIterable, Identifiable {
        case clean, uninstall, analyze, optimize, status, purge, history
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .clean: "internaldrive"
            case .uninstall: "app.dashed"
            case .analyze: "chart.bar.doc.horizontal"
            case .optimize: "wrench.and.screwdriver"
            case .status: "heart.text.square"
            case .purge: "hammer"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    @State private var selection: SidebarItem? = .clean

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.label, systemImage: item.icon)
                    .tag(item)
            }
            .navigationTitle("myKikau")
            .frame(minWidth: 180)
        } detail: {
            switch selection {
            case .clean: CleanView()
            case .uninstall: UninstallView()
            case .analyze: AnalyzeView()
            case .optimize: OptimizeView()
            case .status: StatusView()
            case .purge: PurgeView()
            case .history: HistoryView()
            default: CleanView()
            }
        }
    }
}