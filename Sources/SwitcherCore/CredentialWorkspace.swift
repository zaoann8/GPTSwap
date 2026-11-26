#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// A private, recoverable directory for a single official CLI invocation.
struct CredentialWorkspace: Sendable {
    let home: URL
    private let descriptor: Int32

    var authFile: URL { home.appending(path: "auth.json") }
    private var baselineFile: URL { home.appending(path: "baseline") }

    init(profileHome: URL) throws {
        let lock = profileHome.appending(path: "credential-operation.lock")
        let handle = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard handle >= 0 else { throw Failure.unavailable }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(handle)
            throw AccountStoreError.accountOperationInProgress
        }
        descriptor = handle
        home = profileHome.appending(path: "credential-operation", directoryHint: .isDirectory)
    }

    func release() { _ = Darwin.close(descriptor) }

    func prepare(for credential: Data, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: home, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        try Self.digest(credential).write(to: baselineFile, options: .atomic)
    }

    /// An empty result means the child did not replace the saved login, or its
    /// replacement was already committed before the previous process exited.
    func pendingReplacement(current: Data?, fileManager: FileManager) throws -> Data? {
        guard fileManager.fileExists(atPath: home.path) else { return nil }
        guard try fileManager.attributesOfItem(atPath: home.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.unavailable
        }
        guard fileManager.fileExists(atPath: authFile.path) else { return nil }
        guard try fileManager.attributesOfItem(atPath: authFile.path)[.type] as? FileAttributeType == .typeRegular,
              try fileManager.attributesOfItem(atPath: baselineFile.path)[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.unavailable
        }
        let candidate = try Data(contentsOf: authFile)
        guard candidate != current else { return nil }
        let baseline = try Data(contentsOf: baselineFile)
        guard let current else {
            guard baseline.count == SHA256.byteCount else { throw Failure.unavailable }
            return candidate
        }
        if baseline == Self.digest(candidate) { return nil }
        guard baseline == Self.digest(current) else { throw Failure.outdated }
        return candidate
    }

    func clean(fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: home.path) { try fileManager.removeItem(at: home) }
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private enum Failure: LocalizedError {
        case unavailable, outdated

        var errorDescription: String? {
            switch self {
            case .unavailable: "The private credential workspace could not be verified."
            case .outdated: "The saved login changed while Codex was using it. The pending files were retained for recovery."
            }
        }
    }
}
#endif
