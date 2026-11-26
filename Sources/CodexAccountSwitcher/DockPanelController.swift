import AppKit
import SwiftUI

@MainActor
protocol DockPanelWindow: AnyObject {
    func revealDockPanel()
}

@MainActor
final class DockPanelController {
    private var window: (any DockPanelWindow)?

    func show(makeWindow: () -> any DockPanelWindow) {
        let panel = window ?? makeWindow()
        window = panel
        panel.revealDockPanel()
    }

    static func makeWindow(model: AppModel, updater: AppUpdater) -> NSWindow {
        let content = NSHostingController(rootView: ScrollView {
            MenuBarPopover(model: model, updater: updater)
        })
        let size = NSSize(width: MenuBarPopover.contentWidth, height: 510)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentViewController = content
        window.title = "gptswap"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: size.width, height: 240)
        window.contentMaxSize = NSSize(width: size.width, height: 2000)
        window.setContentSize(size)
        window.center()
        return window
    }
}

extension NSWindow: DockPanelWindow {
    func revealDockPanel() {
        if isMiniaturized { deminiaturize(nil) }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
