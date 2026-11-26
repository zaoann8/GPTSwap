import Foundation
import SwiftUI
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct DockPanelTests {
    @Test func applicationEntryDoesNotRegisterUnrequestedSwiftUIScenes() {
        let entryPoint: Any.Type = SwitcherApp.self
        #expect(!(entryPoint is any SwiftUI.App.Type))
    }

    @Test func dockReopenEventHasAnAppDelegateHandler() {
        let selector = NSSelectorFromString("applicationShouldHandleReopen:hasVisibleWindows:")
        #expect(SwitcherAppDelegate.instancesRespond(to: selector))
    }

    @Test func dockReopensTheSamePanel() {
        let controller = DockPanelController()
        let panel = TestDockPanel()
        var created = 0
        controller.show {
            created += 1
            return panel
        }
        controller.show {
            created += 1
            return TestDockPanel()
        }
        #expect(created == 1)
        #expect(panel.reveals == 2)
    }
}

@MainActor
private final class TestDockPanel: DockPanelWindow {
    private(set) var reveals = 0
    func revealDockPanel() { reveals += 1 }
}
