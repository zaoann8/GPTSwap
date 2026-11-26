import Foundation
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct AppUpdaterTests {
    @Test(arguments: [false, true])
    func personalBuildKeepsUpdatesDisabled(hasOldFeedEntry: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var info = [
            "CFBundleIdentifier": "local.switcher.personal-updater-tests",
            "CFBundleShortVersionString": "0.2.1",
        ]
        if hasOldFeedEntry {
            info["SUFeedURL"] = "https://example.invalid/appcast.xml"
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appending(path: "Info.plist"))

        let adapter = AppUpdater(bundle: try #require(Bundle(url: directory)))
        adapter.start()
        adapter.setAutomaticallyChecks(true)
        adapter.checkForUpdates()

        #expect(adapter.currentVersion == "0.2.1")
        #expect(!adapter.supportsUpdates)
        #expect(!adapter.automaticallyChecks)
        #expect(!adapter.canCheckForUpdates)
        #expect(!adapter.isInstalling)
        #expect(adapter.availableVersion == nil)
        #expect(adapter.lastError == nil)
    }
}
