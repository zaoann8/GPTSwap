import Combine
import Foundation

// 自用版只显示本地版本。保留界面使用的停用状态。
@MainActor
final class AppUpdater: ObservableObject {
    let availableVersion: String? = nil
    let canCheckForUpdates = false
    let isInstalling = false
    let lastError: String? = nil
    let automaticallyChecks = false
    let supportsUpdates = false
    var accountOperationInProgress = false

    let currentVersion: String

    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    func start() {}
    func checkForUpdates() {}
    func setAutomaticallyChecks(_: Bool) {}
}
