import AppKit
import SwiftUI
import Core
import Features
import UI

/// Main app entry point. Window + menu bar HUD.
@main
struct myKikauApp: App {
    @StateObject private var updaterViewModel = UpdaterViewModel()
    @AppStorage(AppStorageKey.showDockIcon) private var showDockIcon = true
    // Gates the launch-time Analyze preload below — only set once the user
    // has actually opened Analyse at least once (see AnalyzeView.onAppear).
    @AppStorage(AppStorageKey.hasUsedAnalyze) private var hasUsedAnalyze = false
    // Shared singleton, not a fresh instance — @ObservedObject here just
    // subscribes this Scene to its existing @Published changes so the menu
    // bar icon can react to the last Scan Everything result.
    @ObservedObject private var scanCoordinator = ScanEverythingCoordinator.shared

    /// Whether the menu bar icon's accent dot should show. Deliberately a
    /// high bar (500MB, matching the "worth flagging" threshold already used
    /// for stale-app suggestions in UninstallView) — this is meant to say
    /// "there's something worth a look," not turn on for every stray cache
    /// file, or it stops meaning anything.
    private var hasActionableFindings: Bool {
        scanCoordinator.combinedReclaimableBytes >= 500_000_000
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: a WindowGroup hands back a *new*
        // window every time `openWindow(id: "main")` is called (e.g. from
        // the menu bar HUD's Dashboard/Clean buttons), so clicking those
        // twice left two overlapping main windows open. `Window` is SwiftUI's
        // singleton-scene type — macOS reuses the one existing window and
        // just brings it forward on repeat `openWindow` calls, same as a
        // Settings window.
        Window("myKikau", id: "main") {
            RootView()
                .frame(minWidth: 800, minHeight: 500)
                .environmentObject(updaterViewModel)
                .onAppear {
                    DockIconController.apply(showDockIcon: showDockIcon)
                    schedulePreloadIfNeeded()
                }
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
            // .renderingMode(.template) is the important part here: SwiftUI's
            // Image(nsImage:) doesn't reliably inherit NSImage.isTemplate on
            // its own inside a MenuBarExtra label, which is why this icon was
            // staying teal-tinted instead of following the other menu bar
            // icons between light/dark menu bar themes. Forcing template mode
            // explicitly makes AppKit treat the drawn shape as a plain alpha
            // mask and recolor it exactly like every other status item.
            //
            // The accent dot is a deliberately separate, NON-template layer
            // stacked on top rather than baked into the template image — a
            // template image is a single alpha mask recolored as one flat
            // unit, so any color drawn *inside* it would just get flattened
            // to the same black/white as everything else. Keeping it as its
            // own small Circle is what lets it stay teal while the base icon
            // still blends in.
            ZStack(alignment: .topTrailing) {
                Image(nsImage: DockIconController.menuBarImage())
                    .renderingMode(.template)
                if hasActionableFindings {
                    Circle()
                        .fill(Color.teal)
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: -1)
                }
            }
        }
        .menuBarExtraStyle(.window)

        // A real Preferences window — SwiftUI's `Settings` scene wires this
        // up to ⌘, and an App menu "Settings…" item automatically. Previously
        // the app's only toggle (Show Dock Icon) lived inside About, and there
        // was no Launch at Login option anywhere.
        Settings {
            SettingsView()
        }
    }

    /// Warms the Analyze disk-usage cache in the background a few seconds
    /// after launch, so opening Analyse later in the session shows results
    /// immediately instead of requiring a manual "Scan Home" first. Gated on
    /// `hasUsedAnalyze` (skip entirely for people who've never opened that
    /// screen — no point paying the cost for a feature they don't use) and,
    /// inside `AnalyzeScanSession.preload`, on a persisted once-a-day check.
    /// The delay keeps this out of the way of whatever actually happens
    /// right at launch (window animation, Sparkle's update check, etc.).
    private func schedulePreloadIfNeeded() {
        guard hasUsedAnalyze else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            AnalyzeScanSession.shared.preload(FileManager.default.homeDirectoryForCurrentUser)
        }
    }
}

enum DockIconController {
    static func apply(showDockIcon: Bool) {
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    /// The menu bar icon. Loads a purpose-built monochrome vector asset
    /// (`AppIcon/MenuBarIcon.pdf` — a simplified silhouette of the same
    /// broom/fan mark as the full-color app icon, redrawn bold enough to
    /// still read clearly at 18x18pt) bundled into `Contents/Resources` by
    /// `scripts/build-app.sh`.
    ///
    /// This replaced an in-code `NSBezierPath` drawing that also set
    /// `isTemplate = true` and, in the SwiftUI label, `.renderingMode(.template)`
    /// — correct in theory, but it still wasn't reliably recoloring with the
    /// system menu bar theme in practice. Loading a real bundled template PDF
    /// is the same mechanism Xcode's asset catalogs use under the hood for
    /// template menu bar icons, and doesn't depend on a `lockFocus()`-drawn
    /// NSImage's template flag surviving SwiftUI's `Image(nsImage:)` bridge.
    static func menuBarImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        // Fallback only reached if the bundled PDF is missing — e.g. running
        // via `swift run` in development rather than through
        // scripts/build-app.sh, which is what actually assembles
        // Contents/Resources. Keeps the menu bar from going blank in that case.
        return legacyDrawnImage()
    }

    private static func legacyDrawnImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.isTemplate = true

        image.lockFocus()
        NSColor.black.set()

        let rect = NSRect(origin: .zero, size: size)
        let inset: CGFloat = 1.5
        let outer = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: outer, xRadius: 4.5, yRadius: 4.5)
        path.lineWidth = 1.5
        path.stroke()

        let cx = rect.midX
        let cy = rect.midY
        let knotW: CGFloat = 6
        let knotH: CGFloat = 3.5
        let knot = NSBezierPath()
        knot.move(to: NSPoint(x: cx - knotW / 2, y: cy - knotH / 2))
        knot.curve(to: NSPoint(x: cx + knotW / 2, y: cy + knotH / 2),
                   controlPoint1: NSPoint(x: cx - knotW / 2, y: cy + knotH),
                   controlPoint2: NSPoint(x: cx + knotW / 2, y: cy - knotH))
        knot.curve(to: NSPoint(x: cx - knotW / 2, y: cy - knotH / 2),
                   controlPoint1: NSPoint(x: cx + knotW / 2, y: cy + knotH),
                   controlPoint2: NSPoint(x: cx - knotW / 2, y: cy - knotH))
        knot.lineWidth = 1.2
        knot.stroke()

        image.unlockFocus()
        return image
    }
}

/// Shows the first-launch onboarding once, then the real app.
struct RootView: View {
    @AppStorage(AppStorageKey.didCompleteOnboarding) private var didCompleteOnboarding = false

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
            case .uninstall: "Apps"
            case .analyze: "Analyse"
            case .duplicates: "Files"
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
