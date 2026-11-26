import SwitcherCore
import AppKit
import Foundation

enum DesktopControllerError: LocalizedError, Sendable {
    case quitRequestFailed
    case didNotExit
    case reopenFailed
    case differentInstallationRunning

    var errorDescription: String? {
        switch self {
        case .quitRequestFailed:
            "Codex Desktop rejected the quit request."
        case .didNotExit:
            "Codex Desktop did not finish quitting within 30 seconds. Finish or stop active tasks and close Desktop, then switch again. The account has not changed."
        case .reopenFailed:
            "Codex Desktop could not be reopened. Open it manually to continue."
        case .differentInstallationRunning:
            "Another Codex Desktop installation is running. Quit it before switching accounts."
        }
    }
}

struct DesktopQuitWaiter: Sendable {
    var timeout: Duration = .seconds(30)
    var pollInterval: Duration = .milliseconds(100)

    func wait(isRunning: @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await isRunning() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw DesktopControllerError.didNotExit }
            try await Task.sleep(for: min(pollInterval, deadline - clock.now))
        }
        try Task.checkCancellation()
    }
}

struct DesktopController: DesktopControlling {
    private let bundleIdentifiers = ["com.openai.codex"]
    private let applicationPaths = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
    let officialInstallation: OfficialCodexInstallation?

    init(officialInstallation: OfficialCodexInstallation? = nil) {
        self.officialInstallation = officialInstallation
    }

    func closeDesktop() async throws {
        let running = runningDesktopApplications
        if let officialInstallation {
            let verifiedApp = try officialInstallation.verify().application
            guard running.allSatisfy({ $0.bundleURL?.resolvingSymlinksInPath() == verifiedApp }) else {
                throw DesktopControllerError.differentInstallationRunning
            }
        }
        guard !running.isEmpty else { return }
        for application in running where !application.isTerminated {
            let processIdentifier = application.processIdentifier
            guard application.terminate() || !isDesktopRunning(processIdentifier: processIdentifier) else {
                throw DesktopControllerError.quitRequestFailed
            }
        }

        try await DesktopQuitWaiter().wait {
            isDesktopRunning
        }
    }

    func reopenDesktop() async throws {
        // Pure CLI users without Codex Desktop installed do not need a desktop launch.
        let url: URL
        if let officialInstallation {
            url = try officialInstallation.verify().application
        } else if let installed = applicationURL() {
            url = installed
        } else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let reopened = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            if officialInstallation != nil, reopened.bundleURL?.resolvingSymlinksInPath() != url {
                throw DesktopControllerError.reopenFailed
            }
        } catch {
            throw DesktopControllerError.reopenFailed
        }
    }

    private func applicationURL() -> URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return applicationPaths
            .map(URL.init(fileURLWithPath:))
            .first(where: { url in
                guard FileManager.default.fileExists(atPath: url.path),
                      let bundleID = Bundle(url: url)?.bundleIdentifier else { return false }
                return bundleIdentifiers.contains(bundleID)
            })
    }

    private var isDesktopRunning: Bool {
        !runningDesktopApplications.isEmpty
    }

    private var runningDesktopApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return bundleIdentifiers.contains(bundleIdentifier)
        }
    }

    private func isDesktopRunning(processIdentifier: pid_t) -> Bool {
        runningDesktopApplications.contains { $0.processIdentifier == processIdentifier }
    }
}
