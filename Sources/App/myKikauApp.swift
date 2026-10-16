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
    /// Gates the launch-time Analyze preload below — only set once the user
    /// has actually opened Analyse at least once (see AnalyzeView.onAppear).
    @AppStorage(AppStorageKey.hasUsedAnalyze) private var hasUsedAnalyze = false
    // Shared singleton, not a fresh instance — @ObservedObject here just
    // subscribes this Scene to its existing @Published changes so the menu
    // bar icon can react to the last Scan Everything result.
    @ObservedObject private var scanCoordinator = ScanEverythingCoordinator.shared
    @AppStorage(AppStorageKey.developerToolsEnabled) private var developerTools = false

    init() {
        BackgroundScanScheduler.shared.start()
        // Log entries are written asynchronously; make sure the last ones
        // reach the disk before the process exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            OperationLog.shared.flush()
        }
    }

    /// Whether the menu bar icon's accent dot should show. Deliberately a
    /// high bar (500MB, matching the "worth flagging" threshold already used
    /// for stale-app suggestions in UninstallView) — this is meant to say
    /// "there's something worth a look," not turn on for every stray cache
    /// file, or it stops meaning anything.
    private var hasActionableFindings: Bool {
        scanCoordinator.combinedReclaimableBytes >= 500_000_000
            || scanCoordinator.systemHealthIssueCount > 0
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
                .frame(minWidth: 860, minHeight: 600)
                .environmentObject(updaterViewModel)
                .onAppear {
                    DockIconController.apply(showDockIcon: showDockIcon)
                    schedulePreloadIfNeeded()
                }
                .onChange(of: showDockIcon) { _, value in
                    DockIconController.apply(showDockIcon: value)
                }
        }
        .defaultSize(width: 1060, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updaterViewModel: updaterViewModel)
            }
            // ⌘1…⌘9 jump straight to a screen, in sidebar order.
            CommandMenu("Go") {
                let items = ContentView.SidebarItem.visibleCases(developerTools: developerTools)
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    if index < 9 {
                        Button(item.label) { AppNavigation.shared.pendingSelection = item }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button(item.label) { AppNavigation.shared.pendingSelection = item }
                    }
                }
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
                .environmentObject(updaterViewModel)
        }
    }

    /// Warms the Analyze whole-disk overview cache in the background a few
    /// seconds after launch, so opening Analyse later in the session shows
    /// results immediately instead of requiring a manual scan first. Gated on
    /// `hasUsedAnalyze` (skip entirely for people who've never opened that
    /// screen — no point paying the cost for a feature they don't use) and,
    /// inside `AnalyzeScanSession.preloadOverview`, on a persisted once-a-day
    /// check. The delay keeps this out of the way of whatever actually happens
    /// right at launch (window animation, Sparkle's update check, etc.).
    private func schedulePreloadIfNeeded() {
        guard hasUsedAnalyze else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            AnalyzeScanSession.shared.preloadOverview()
        }
    }
}

@MainActor
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
           let image = NSImage(contentsOf: url)
        {
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
        knot.curve(
            to: NSPoint(x: cx + knotW / 2, y: cy + knotH / 2),
            controlPoint1: NSPoint(x: cx - knotW / 2, y: cy + knotH),
            controlPoint2: NSPoint(x: cx + knotW / 2, y: cy - knotH)
        )
        knot.curve(
            to: NSPoint(x: cx - knotW / 2, y: cy - knotH / 2),
            controlPoint1: NSPoint(x: cx + knotW / 2, y: cy + knotH),
            controlPoint2: NSPoint(x: cx - knotW / 2, y: cy - knotH)
        )
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
        case status, clean, uninstall, analyze, duplicates, network, optimize, startup, purge, history, about
        var id: String {
            rawValue
        }

        /// Explicit display strings rather than `rawValue.capitalized` — the
        /// case names are American-spelled internal identifiers ("analyze",
        /// "optimize"), but the app is NZ/AU-facing, so what's actually shown
        /// uses "Analyse"/"Optimise".
        var label: String {
            switch self {
            case .status: String(localized: "Overview")
            case .clean: String(localized: "Clean up")
            case .uninstall: String(localized: "Applications")
            case .analyze: String(localized: "Storage")
            case .duplicates: String(localized: "My files")
            case .network: String(localized: "Network")
            case .optimize: String(localized: "System care")
            case .startup: String(localized: "Startup")
            case .purge: String(localized: "Purge")
            case .history: String(localized: "History")
            case .about: String(localized: "About")
            }
        }

        /// Sidebar items shown to the user, in order. Purge is a developer
        /// feature, shown only when "Developer tools" is on in Settings; any
        /// feature an administrator has disabled by policy is left out.
        static func visibleCases(developerTools: Bool) -> [SidebarItem] {
            let policy = ManagedPolicy.shared
            return allCases.filter { item in
                if item == .purge, !developerTools {
                    return false
                }
                if item == .status || item == .about || item == .history {
                    return true
                }
                return !policy.isFeatureDisabled(item.rawValue)
            }
        }

        /// Sidebar grouping.
        enum Group: String, CaseIterable, Identifiable {
            case overview = "Overview"
            case cleanUp = "Clean Up"
            case inspect = "Inspect"
            case maintain = "Maintain"
            case app = "myKikau"
            var id: String {
                rawValue
            }

            /// Caption shown above the group, if it has one.
            var title: String? {
                switch self {
                case .overview, .app: nil
                default: rawValue
                }
            }
        }

        var group: Group {
            switch self {
            case .status: .overview
            case .clean, .uninstall, .duplicates, .purge: .cleanUp
            case .analyze, .network: .inspect
            case .optimize, .startup: .maintain
            case .history, .about: .app
            }
        }

        var icon: String {
            switch self {
            case .status: "sparkles"
            case .clean: "internaldrive"
            case .uninstall: "app.dashed"
            case .analyze: "chart.bar.doc.horizontal"
            case .duplicates: "doc.on.doc"
            case .network: "wifi"
            case .optimize: "wrench.and.screwdriver"
            case .startup: "power"
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
            case .status: CareTheme.accent
            case .clean: CareTheme.accent
            case .uninstall: .purple
            case .analyze: .teal
            case .duplicates: .pink
            case .network: .indigo
            case .optimize: CareTheme.accent
            case .startup: .green
            case .purge: .brown
            case .history: .mint
            case .about: .secondary
            }
        }
    }

    // Status is the landing screen — it acts as the dashboard/hub that
    // launches every other feature. The last screen used is restored on launch.
    @State private var selection: SidebarItem?
    @AppStorage(AppStorageKey.lastSidebarSelection) private var storedSelection = SidebarItem.status.rawValue
    @AppStorage(AppStorageKey.developerToolsEnabled) private var developerTools = false
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var deletionActivity = DeletionActivity.shared
    @ObservedObject private var work = WorkCoordinator.shared

    private var visibleItems: [SidebarItem] {
        SidebarItem.visibleCases(developerTools: developerTools)
    }

    var body: some View {
        let items = visibleItems
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 31, height: 35).background(CareTheme.accent, in: RoundedRectangle(cornerRadius: 11))
                    Text("myKikau").foregroundStyle(CareTheme.ink).font(.system(size: 23, weight: .bold, design: .rounded)).tracking(-0.8)
                }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 14)
                List {
                    ForEach(SidebarItem.Group.allCases) { group in
                        let groupItems = items.filter { $0.group == group }
                        if !groupItems.isEmpty {
                            Section {
                                ForEach(groupItems) { item in
                                    Button { selection = item } label: {
                                        SidebarRow(item: item, selected: selection == item)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(
                                                selection == item ? CareTheme.lilac : .clear,
                                                in: RoundedRectangle(cornerRadius: 10)
                                            )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selection == item ? [.isSelected] : [])
                                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                                    .listRowBackground(Color.clear)
                                }
                            } header: {
                                // The first and last groups need no caption;
                                // skipping them keeps the list inside the window.
                                if let title = group.title {
                                    Text(title).foregroundStyle(CareTheme.secondaryInk)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .navigationTitle("")
                // No switching screens while files are being removed.
                .disabled(deletionActivity.isRunning)
                Divider().padding(.horizontal, 14)
                if let active = work.activity {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) { ProgressView().controlSize(.small); Text(active.title).font(.caption).lineLimit(2) }
                        if work.canCancel {
                            Button("Cancel", action: work.cancel).font(.caption)
                        }
                    }.padding(16)
                } else {
                    Label(Host.current().localizedName ?? "This Mac", systemImage: "laptopcomputer")
                        .font(.caption).foregroundStyle(CareTheme.secondaryInk).lineLimit(2).padding(16)
                }
            }
            .background(CareTheme.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 230)
        } detail: {
            // A screen that's hidden (developer tools off, or disabled by
            // policy) falls back to Status — e.g. a stale stored selection.
            Group {
                switch selection.flatMap({ items.contains($0) ? $0 : nil }) ?? .status {
                case .status: StatusView(onNavigate: { selection = $0 })
                case .clean: CleanView()
                case .uninstall: UninstallView()
                case .analyze: AnalyzeView()
                case .duplicates: DuplicatesView()
                case .network: NetworkView()
                case .optimize: OptimizeView()
                case .startup: StartupView()
                case .purge: PurgeView()
                case .history: HistoryView()
                case .about: AboutView()
                }
            }
            // A screen whose content doesn't fill the pane (an empty state)
            // keeps its header at the top instead of floating mid-window.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CareTheme.background)
        }
        .tint(CareTheme.accent)
        .accentColor(CareTheme.accent)
        .onAppear {
            if selection == nil {
                selection = SidebarItem(rawValue: storedSelection) ?? .status
            }
        }
        .onChange(of: selection) { _, value in
            if let value {
                storedSelection = value.rawValue
            }
        }
        // Picked up when the menu bar HUD or a ⌘-number shortcut requests a
        // specific screen.
        .onReceive(navigation.$pendingSelection) { pending in
            guard let pending else { return }
            if items.contains(pending), !deletionActivity.isRunning {
                selection = pending
            }
            navigation.pendingSelection = nil
        }
    }
}

private struct SidebarRow: View {
    let item: ContentView.SidebarItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(item.tint.opacity(selected ? 0.22 : 0.14))
                    .frame(width: 24, height: 24)
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            Text(item.label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(CareTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
