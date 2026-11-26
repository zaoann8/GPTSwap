import Foundation

public protocol ConsolidatingBackupCredentialVault: BackupCredentialVault {
    func consolidate(accountID: UUID, validate: (Data) throws -> Void) throws
}

public protocol CredentialRecordStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

#if os(macOS)
import Darwin

/// All credentials live in one protected record. Only its lock file lives on disk.
public final class ConsolidatedCredentialVault: ConsolidatingBackupCredentialVault, @unchecked Sendable {
    private struct Document: Codable {
        var version = 1
        var credentials: [String: Data] = [:]
        var deleted: Set<String> = []
        var pendingLegacyRemoval: Set<String> = []
        var retiredLegacy: Set<String> = []
    }

    private let storage: any CredentialRecordStorage
    private let previousVault: any BackupCredentialVault
    private let lockURL: URL
    private let threadLock = NSLock()

    public init(storage: any CredentialRecordStorage, previousVault: any BackupCredentialVault, lockURL: URL) {
        self.storage = storage
        self.previousVault = previousVault
        self.lockURL = lockURL
    }

    public static func live() -> ConsolidatedCredentialVault {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "local.gptswap", directoryHint: .isDirectory)
        return .init(storage: SingleKeychainCredentialRecord(), previousVault: KeychainBackupCredentialVault(),
                     lockURL: root.appending(path: ".credential-vault.lock"))
    }

    public func read(accountID: UUID) throws -> Data? {
        try withLock { try load().credentials[accountID.uuidString] }
    }

    public func write(_ credential: Data, accountID: UUID) throws {
        try withLock {
            var document = try load()
            let key = accountID.uuidString
            try checkCredential(credential)
            guard !document.deleted.contains(key) else { throw Failure.removedAccount }
            if let existing = document.credentials[key],
               let savedAt = AccountStore.refreshTime(of: existing),
               let candidateAt = AccountStore.refreshTime(of: credential), savedAt > candidateAt {
                throw Failure.staleCredential
            }
            document.credentials[key] = credential
            if !document.retiredLegacy.contains(key) { document.pendingLegacyRemoval.insert(key) }
            try commit(document)
            try finishLegacyRemoval(accountID: accountID, document: &document)
        }
    }

    public func addIfAbsent(_ credential: Data, accountID: UUID) throws -> Bool {
        try withLock {
            var document = try load()
            let key = accountID.uuidString
            guard document.credentials[key] == nil else { return false }
            guard !document.deleted.contains(key) else { throw Failure.removedAccount }
            try checkCredential(credential)
            document.credentials[key] = credential
            if !document.retiredLegacy.contains(key) { document.pendingLegacyRemoval.insert(key) }
            try commit(document)
            try finishLegacyRemoval(accountID: accountID, document: &document)
            return true
        }
    }

    public func remove(accountID: UUID) throws {
        try withLock {
            var document = try load()
            let key = accountID.uuidString
            document.credentials.removeValue(forKey: key)
            // Keep a tombstone even after deleting the last account: an old copy
            // of a per-account item must never bring a removed account back.
            document.deleted.insert(key)
            if !document.retiredLegacy.contains(key) { document.pendingLegacyRemoval.insert(key) }
            try commit(document)
            try finishLegacyRemoval(accountID: accountID, document: &document)
        }
    }

    public func consolidate(accountID: UUID, validate: (Data) throws -> Void) throws {
        try withLock {
            var document = try load()
            let key = accountID.uuidString
            if let current = document.credentials[key] {
                try validate(current)
                try finishLegacyRemoval(accountID: accountID, document: &document)
                return
            }
            guard !document.deleted.contains(key), !document.retiredLegacy.contains(key),
                  let previous = try previousVault.read(accountID: accountID) else { return }
            try checkCredential(previous)
            try validate(previous)
            document.credentials[key] = previous
            document.pendingLegacyRemoval.insert(key)
            try commit(document)
            try finishLegacyRemoval(accountID: accountID, document: &document)
        }
    }

    private func finishLegacyRemoval(accountID: UUID, document: inout Document) throws {
        let key = accountID.uuidString
        guard document.pendingLegacyRemoval.contains(key) else { return }
        // The new payload was written and read back before any source is removed.
        // A failed cleanup remains journaled in the protected record for retry.
        try previousVault.remove(accountID: accountID)
        document.pendingLegacyRemoval.remove(key)
        document.retiredLegacy.insert(key)
        try commit(document)
    }

    private func load() throws -> Document {
        guard let bytes = try storage.read() else { return Document() }
        guard bytes.count <= 16_777_216 else { throw Failure.invalidRecord }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: bytes) }
        catch { throw Failure.invalidRecord }
        guard document.version == 1 else { throw Failure.unsupportedVersion }
        let keys = Set(document.credentials.keys).union(document.deleted)
            .union(document.pendingLegacyRemoval).union(document.retiredLegacy)
        guard keys.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }),
              Set(document.credentials.keys).isDisjoint(with: document.deleted),
              document.pendingLegacyRemoval.isDisjoint(with: document.retiredLegacy) else {
            throw Failure.invalidRecord
        }
        for credential in document.credentials.values { try checkCredential(credential) }
        return document
    }

    private func checkCredential(_ data: Data) throws {
        guard !data.isEmpty, data.count <= ParsedCredential.maximumCredentialBytes else { throw Failure.invalidRecord }
    }

    private func commit(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(document)
        guard bytes.count <= 16_777_216 else { throw Failure.invalidRecord }
        try storage.write(bytes)
        guard try storage.read() == bytes else { throw Failure.verificationFailed }
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        threadLock.lock()
        defer { threadLock.unlock() }
        let parent = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.invalidLock
        }
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.invalidLock }
        defer { _ = Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == geteuid(),
              attributes.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw Failure.invalidLock }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AccountStoreError.accountOperationInProgress }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private enum Failure: LocalizedError {
        case invalidRecord, unsupportedVersion, verificationFailed, invalidLock, removedAccount, staleCredential
        var errorDescription: String? {
            switch self {
            case .invalidRecord: "The credential vault is damaged or invalid. Existing credentials were not replaced."
            case .unsupportedVersion: "This credential vault was created by a newer gptswap version."
            case .verificationFailed: "The credential vault could not be verified after saving. Retry the operation."
            case .invalidLock: "The private credential vault lock could not be verified."
            case .removedAccount: "This saved login was removed. Reload the account list before retrying."
            case .staleCredential: "A newer saved login already exists. Refresh and retry."
            }
        }
    }
}
#endif
