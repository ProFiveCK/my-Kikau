import AppKit
import SwiftUI

/// All in-app Settings shortcuts open the same native Settings scene.
/// A menu-bar-only app may be inactive when clicked, so opening the scene
/// must also dismiss its source popover and focus the actual Settings window.
@MainActor
final class SettingsPresentation {
    static let shared = SettingsPresentation()
    private weak var window: NSWindow?
    private var needsFocus = false

    func open(using openSettings: OpenSettingsAction, dismissing sourceWindow: NSWindow? = nil) {
        needsFocus = true
        sourceWindow?.close()
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        focusIfReady()
    }

    func register(_ window: NSWindow) {
        self.window = window
        // The hosting view can attach before SwiftUI has finished presenting
        // the window. Focus it after that presentation has completed.
        DispatchQueue.main.async { [weak self] in self?.focusIfReady() }
    }

    private func focusIfReady() {
        guard needsFocus, let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        needsFocus = false
    }
}

struct AppSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @StateObject private var source = SettingsSourceWindow()
    private let dismissesSourceWindow: Bool
    private let label: Label

    init(dismissesSourceWindow: Bool = false, @ViewBuilder label: () -> Label) {
        self.dismissesSourceWindow = dismissesSourceWindow
        self.label = label()
    }

    var body: some View {
        Button {
            SettingsPresentation.shared.open(using: openSettings, dismissing: dismissesSourceWindow ? source.window : nil)
        } label: { label }
            .background(SettingsWindowReader { source.window = $0 })
    }
}

@MainActor
private final class SettingsSourceWindow: ObservableObject {
    weak var window: NSWindow?
}

/// Captures only the window hosting this view, without relying on SwiftUI's
/// private window identifiers or whichever other window currently has focus.
struct SettingsWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context _: Context) -> ReaderView {
        ReaderView(onWindow: onWindow)
    }

    func updateNSView(_ view: ReaderView, context _: Context) {
        view.onWindow = onWindow
        if let window = view.window {
            onWindow(window)
        }
    }

    final class ReaderView: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder _: NSCoder) {
            nil
        }

        /// This observes a window; it must never intercept Settings controls
        /// or the menu-bar button sitting in front of it.
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow(window)
            }
        }
    }
}
