import AppKit
import SwiftUI

/// Resolves directly to the SwiftUI.State property wrapper, including under Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
@MainActor
struct SwitcherApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = SwitcherAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        installMainMenu(in: application, delegate: delegate)
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func installMainMenu(in application: NSApplication, delegate: SwitcherAppDelegate) {
        let mainMenu = NSMenu()
        let appItem = mainMenu.addItem(withTitle: "gptswap", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appItem.title)
        appItem.submenu = appMenu

        appMenu.addItem(withTitle: "About gptswap", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide gptswap", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        delegate.quitMenuItem = appMenu.addItem(
            withTitle: delegate.model.text("quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editItem = mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: editItem.title)
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = mainMenu.addItem(withTitle: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: windowItem.title)
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        application.windowsMenu = windowMenu
        application.mainMenu = mainMenu
    }
}
