#if os(macOS)
import Foundation
import Security

public struct OfficialCodexInstallation: Sendable {
    public struct Failure: LocalizedError, Sendable {
        public let errorDescription: String?

        fileprivate init(_ message: String) { errorDescription = message }
    }

    public let applicationURL: URL

    public init(applicationURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app")) {
        self.applicationURL = applicationURL
    }

    public func verify() throws -> (application: URL, executable: URL) {
        let app = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw Failure("The official ChatGPT app was not found in Applications.")
        }
        let cli = app.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        ).resolvingSymlinksInPath()
        guard cli.pathComponents.starts(with: app.pathComponents),
              FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw Failure("The official ChatGPT app's bundled Codex executable is missing or outside the app bundle.")
        }
        try Self.checkSignature(app, identifier: "com.openai.codex")
        try Self.checkSignature(cli, identifier: "codex")
        return (app, cli)
    }

    private static func checkSignature(_ url: URL, identifier: String) throws {
        let requirementSource = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        let defaultFlags = SecCSFlags(rawValue: 0)
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, defaultFlags, &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(requirementSource as CFString, defaultFlags, &requirement) == errSecSuccess,
              let requirement else {
            throw Failure("Unable to read the official signature for \(url.lastPathComponent).")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures))
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw Failure("Signature verification failed for \(url.lastPathComponent) (\(status)).")
        }
    }
}
#endif
