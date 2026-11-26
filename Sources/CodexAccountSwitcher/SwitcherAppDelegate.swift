import AppKit
import Combine
import UserNotifications

@MainActor
final class SwitcherAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel.live()
    let updater = AppUpdater()
    weak var quitMenuItem: NSMenuItem?

    private var wakeObservation: AnyCancellable?
    private let dockPanel = DockPanelController()
    private var menuBarItem: MenuBarItemController?
    private var appliedDockVisibility: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onSettledChange = { [weak self] in
            guard let self else { return }
            self.updater.accountOperationInProgress = self.model.isMutating || self.model.isAddingAccount
            self.menuBarItem?.refresh()
            self.applyDockVisibility()
            let quitTitle = self.model.text("quit")
            if self.quitMenuItem?.title != quitTitle { self.quitMenuItem?.title = quitTitle }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            model.onLowUsage = { [weak model] title, message in
                model?.postLowUsageNotification(title: title, message: message)
            }
        }
        updater.start()
        menuBarItem = MenuBarItemController(model: model, updater: updater)
        wakeObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.menuBarItem?.refresh()
                    self?.model.refreshWeeklyUsage()
                }
            }
        Task { await model.startBackgroundUsageRefresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dockPanel.show { DockPanelController.makeWindow(model: model, updater: updater) }
        return false
    }

    private func applyDockVisibility() {
        let visible = model.settings.showsDockIcon
        guard appliedDockVisibility != visible else { return }
        if NSApp.setActivationPolicy(visible ? .regular : .accessory) {
            appliedDockVisibility = visible
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarItem?.stop()
        model.cancelAddingAccount()
        model.stopBackgroundUsageRefresh()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
