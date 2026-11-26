#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import SwitcherCore

struct ConsolidatedCredentialVaultTests {
    @Test func addRefreshRemoveAndRestartKeepSiblingCredentialsAndOneRecord() throws {
        let f = VaultFixture()
        defer { f.clean() }
        let ids = (0..<3).map { _ in UUID() }
        for (index, id) in ids.enumerated() { try f.vault.write(Data("token-\(index)".utf8), accountID: id) }
        let renewed = Data("renewed".utf8)
        try f.vault.write(renewed, accountID: ids[1])
        #expect(try !f.vault.addIfAbsent(Data("outdated".utf8), accountID: ids[1]))
        try f.vault.remove(accountID: ids[0])
        let reopened = f.makeVault()
        #expect(try reopened.read(accountID: ids[0]) == nil)
        #expect(try reopened.read(accountID: ids[1]) == renewed)
        #expect(try reopened.read(accountID: ids[2]) == Data("token-2".utf8))
        try reopened.remove(accountID: ids[1])
        try reopened.remove(accountID: ids[2])
        #expect(f.storage.bytes != nil)
        for id in ids { #expect(try reopened.read(accountID: id) == nil) }
        #expect(SingleKeychainCredentialRecord.serviceName == "local.gptswap.backup")
        #expect(SingleKeychainCredentialRecord.accountName == "credential-vault-v1")
    }

    @Test func migrationValidatesBeforeWritingAndPreservesNewerSharedCredential() throws {
        let f = VaultFixture()
        defer { f.clean() }
        let id = UUID()
        let original = Data("old-test-token".utf8)
        try f.previous.write(original, accountID: id)
        #expect(throws: FixtureError.self) {
            try f.vault.consolidate(accountID: id) { _ in throw FixtureError.denied }
        }
        #expect(f.storage.bytes == nil)
        #expect(try f.previous.read(accountID: id) == original)
        try f.vault.consolidate(accountID: id) { #expect($0 == original) }
        #expect(try f.previous.read(accountID: id) == nil)
        let newer = Data("new-token".utf8)
        try f.vault.write(newer, accountID: id)
        try f.previous.write(original, accountID: id) // An old app recreated its old item.
        try f.vault.consolidate(accountID: id) { #expect($0 == newer) }
        #expect(try f.vault.read(accountID: id) == newer)
    }

    @Test(arguments: [false, true])
    func failedWriteOrReadbackDoesNotDeleteTheMigrationSource(readbackFails: Bool) throws {
        let f = VaultFixture()
        defer { f.clean() }
        let id = UUID()
        let token = Data("source".utf8)
        try f.previous.write(token, accountID: id)
        if readbackFails { f.storage.failReadAfterWrite = true }
        else { f.storage.failWriteNumber = 1 }
        #expect(throws: (any Error).self) { try f.vault.consolidate(accountID: id) { _ in } }
        #expect(try f.previous.read(accountID: id) == token)
        f.storage.failReadAfterWrite = false
        f.storage.failWriteNumber = nil
        try f.makeVault().consolidate(accountID: id) { #expect($0 == token) }
        #expect(try f.previous.read(accountID: id) == nil)
        #expect(try f.vault.read(accountID: id) == token)
    }

    @Test(arguments: [false, true])
    func migrationCleanupCanResumeAfterSourceRemovalOrFinalCommitFailure(finalCommitFails: Bool) throws {
        let f = VaultFixture()
        defer { f.clean() }
        let id = UUID()
        let token = Data("recoverable".utf8)
        try f.previous.write(token, accountID: id)
        if finalCommitFails { f.storage.failWriteNumber = 2 }
        else { f.previous.deniesRemoval = true }
        #expect(throws: (any Error).self) { try f.vault.consolidate(accountID: id) { _ in } }
        #expect(try f.vault.read(accountID: id) == token)
        f.storage.failWriteNumber = nil
        f.previous.deniesRemoval = false
        try f.makeVault().consolidate(accountID: id) { #expect($0 == token) }
        #expect(try f.previous.read(accountID: id) == nil)
    }

    @Test func failedDeletionCanRetryAndCannotResurrectAnOldAccount() throws {
        let f = VaultFixture()
        defer { f.clean() }
        let id = UUID(), sibling = UUID()
        try f.previous.write(Data("old".utf8), accountID: id)
        try f.vault.consolidate(accountID: id) { _ in }
        try f.vault.write(Data("sibling".utf8), accountID: sibling)
        f.storage.failWriteNumber = f.storage.writes + 1
        #expect(throws: FixtureError.self) { try f.vault.remove(accountID: id) }
        #expect(try f.vault.read(accountID: id) == Data("old".utf8))
        f.storage.failWriteNumber = nil
        try f.vault.remove(accountID: id)
        try f.previous.write(Data("stale-source".utf8), accountID: id)
        try f.makeVault().consolidate(accountID: id) { _ in Issue.record("Deleted account was reimported") }
        #expect(try f.vault.read(accountID: id) == nil)
        #expect(try f.vault.read(accountID: sibling) == Data("sibling".utf8))
        #expect(throws: (any Error).self) { try f.makeVault().write(Data("late-worker-write".utf8), accountID: id) }
        #expect(throws: (any Error).self) { _ = try f.makeVault().addIfAbsent(Data("late-add".utf8), accountID: id) }
        #expect(try f.vault.read(accountID: id) == nil)
    }

    @Test func interruptedDeletionPreservesItsTombstoneAndRetriesCleanup() throws {
        let f = VaultFixture()
        defer { f.clean() }
        let id = UUID()
        try f.previous.write(Data("old".utf8), accountID: id)
        f.previous.deniesRemoval = true
        #expect(throws: FixtureError.self) { try f.vault.remove(accountID: id) }
        #expect(try f.vault.read(accountID: id) == nil)
        try f.makeVault().consolidate(accountID: id) { _ in Issue.record("Deleted account was reimported") }
        f.previous.deniesRemoval = false
        try f.makeVault().remove(accountID: id)
        #expect(try f.previous.read(accountID: id) == nil)
    }

    @Test(arguments: [Data("broken-secret-data".utf8), Data(#"{"version":99,"credentials":{},"deleted":[],"pendingLegacyRemoval":[],"retiredLegacy":[]}"#.utf8)])
    func damagedOrFutureVaultIsNotOverwritten(bytes: Data) throws {
        let f = VaultFixture()
        defer { f.clean() }
        f.storage.bytes = bytes
        do {
            try f.vault.write(Data("new".utf8), accountID: UUID())
            Issue.record("Invalid vault was overwritten")
        } catch {
            #expect(!error.localizedDescription.contains("broken-secret-data"))
        }
        #expect(f.storage.bytes == bytes)
        #expect(f.storage.writes == 0)
    }

    @Test func crossInstanceLockRejectsConcurrentAccessAndSymbolicLinks() throws {
        let f = VaultFixture()
        defer { f.clean() }
        _ = try f.vault.read(accountID: UUID())
        let descriptor = Darwin.open(f.lockURL.path, O_RDWR)
        #expect(descriptor >= 0)
        defer { _ = Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: AccountStoreError.accountOperationInProgress) { _ = try f.makeVault().read(accountID: UUID()) }
        _ = flock(descriptor, LOCK_UN)
        try FileManager.default.removeItem(at: f.lockURL)
        let target = f.root.appending(path: "unrelated")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: f.lockURL, withDestinationURL: target)
        #expect(throws: (any Error).self) { _ = try f.makeVault().read(accountID: UUID()) }
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
    }

    @Test func concurrentMutationsKeepAllAccounts() async throws {
        let f = VaultFixture()
        defer { f.clean() }
        let ids = (0..<20).map { _ in UUID() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { try f.vault.write(Data(id.uuidString.utf8), accountID: id) }
            }
            try await group.waitForAll()
        }
        for id in ids { #expect(try f.vault.read(accountID: id) == Data(id.uuidString.utf8)) }
    }

    @Test func activeLoginDoesNotOverwriteANewerTokenDuringMigration() async throws {
        let f = VaultFixture()
        defer { f.clean() }
        let active = f.root.appending(path: "active"), support = f.root.appending(path: "support")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let old = Data(#"{"last_refresh":"2026-11-01T00:00:00Z","tokens":{"account_id":"a"}}"#.utf8)
        let new = Data(#"{"last_refresh":"2026-11-02T00:00:00Z","tokens":{"account_id":"a"}}"#.utf8)
        try old.write(to: active.appending(path: "auth.json"))
        let oldStore = AccountStore(baseURL: support, activeHomeURL: active, backupVault: f.previous)
        let profile = try #require(try await oldStore.syncActiveCredential().accounts.first)
        try f.previous.write(new, accountID: profile.id)
        let upgraded = AccountStore(baseURL: support, activeHomeURL: active, backupVault: f.vault)
        _ = try await upgraded.syncActiveCredential()
        #expect(try f.vault.read(accountID: profile.id) == new)
        #expect(try Data(contentsOf: active.appending(path: "auth.json")) == old)
        #expect(throws: (any Error).self) { try f.makeVault().write(old, accountID: profile.id) }
        #expect(try f.vault.read(accountID: profile.id) == new)
    }

    @Test func oldThreeAccountsSwitchAfterConsolidationAndKeepHistoryAndSettings() async throws {
        let f = VaultFixture()
        defer { f.clean() }
        let active = f.root.appending(path: "active"), support = f.root.appending(path: "support")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let oldStore = AccountStore(baseURL: support, activeHomeURL: active, backupVault: f.previous)
        let history = active.appending(path: "session_index.jsonl")
        let historyBytes = Data("same-old-conversation".utf8)
        try historyBytes.write(to: history)
        var profiles: [AccountProfile] = []
        for name in ["a", "b", "c"] {
            try TestAuthFixture.authJSON(accountID: name).write(to: active.appending(path: "auth.json"))
            profiles = try await oldStore.syncActiveCredential().accounts
        }
        let settings = AppSettings(language: .simplifiedChinese, autoResetEnabled: true)
        try await oldStore.saveSettings(settings)
        let registryBytes = try Data(contentsOf: support.appending(path: "accounts.json"))
        let settingsBytes = try Data(contentsOf: support.appending(path: "settings.json"))
        let store = AccountStore(baseURL: support, activeHomeURL: active, backupVault: f.vault)
        f.storage.deniesReads = true
        _ = try await store.loadRegistry()
        f.storage.deniesReads = false
        #expect(f.storage.bytes == nil) // Listing accounts does not request a Keychain secret.
        #expect(try Data(contentsOf: support.appending(path: "accounts.json")) == registryBytes)
        let service = SwitchService(desktop: VaultTestDesktop(), store: store, codex: CredentialIdentity())
        for profile in profiles + [profiles[0]] {
            try await service.switchAccount(to: profile.id)
            #expect(try await store.loadRegistry().activeAccountID == profile.id)
            #expect(try Data(contentsOf: history) == historyBytes)
            #expect(try Data(contentsOf: active.appending(path: "auth.json")) == f.vault.read(accountID: profile.id))
            #expect(try f.previous.read(accountID: profile.id) == nil)
        }
        #expect(try Data(contentsOf: support.appending(path: "settings.json")) == settingsBytes)
        #expect(try await store.loadSettings() == settings)
    }
}

private enum FixtureError: Error { case denied }
private struct VaultTestDesktop: DesktopControlling {
    func closeDesktop() async throws {}
    func reopenDesktop() async throws {}
}
private struct VaultFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appending(path: "gptswap-shared-vault-\(UUID())")
    let storage = MemoryRecord()
    let previous = PreviousVault()
    let vault: ConsolidatedCredentialVault
    var lockURL: URL { root.appending(path: "vault.lock") }
    init() {
        vault = ConsolidatedCredentialVault(storage: storage, previousVault: previous, lockURL: root.appending(path: "vault.lock"))
    }
    func makeVault() -> ConsolidatedCredentialVault {
        ConsolidatedCredentialVault(storage: storage, previousVault: previous, lockURL: lockURL)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
private final class MemoryRecord: CredentialRecordStorage, @unchecked Sendable {
    var bytes: Data?
    var writes = 0
    var failWriteNumber: Int?
    var failReadAfterWrite = false
    var deniesReads = false
    func read() throws -> Data? {
        if deniesReads { throw FixtureError.denied }
        if failReadAfterWrite && writes > 0 { throw FixtureError.denied }
        return bytes
    }
    func write(_ data: Data) throws {
        writes += 1
        if failWriteNumber == writes { throw FixtureError.denied }
        bytes = data
    }
}
private final class PreviousVault: BackupCredentialVault, @unchecked Sendable {
    private var items: [UUID: Data] = [:]
    var deniesRemoval = false
    func read(accountID: UUID) throws -> Data? { items[accountID] }
    func write(_ credential: Data, accountID: UUID) throws { items[accountID] = credential }
    func remove(accountID: UUID) throws {
        if deniesRemoval { throw FixtureError.denied }
        items.removeValue(forKey: accountID)
    }
}
#endif
