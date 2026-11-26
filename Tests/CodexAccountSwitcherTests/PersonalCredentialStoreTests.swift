import Foundation
import Testing
@testable import SwitcherCore

struct PersonalCredentialStoreTests {

    @Test(arguments: [false, true])
    func missingBackupRecoveryValidatesTheWorkspaceAccount(wrongIdentity: Bool) async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        let target = accounts[1]
        await #expect(throws: CancellationError.self) {
            try await fixture.store.withSavedCredentialHome(id: target.id, operation: { home in
                if wrongIdentity {
                    try fixture.credential("c").write(to: home.appending(path: "auth.json"))
                }
            }, stop: { _ in throw CancellationError() })
        }
        try fixture.vault.remove(accountID: target.id)
        let reopened = AccountStore(baseURL: await fixture.store.baseURL, activeHomeURL: fixture.activeHome,
                                    backupVault: fixture.vault, legacyBackupVault: MemoryCredentialVault())
        if wrongIdentity {
            await #expect(throws: AccountStoreError.self) {
                try await reopened.profile(id: target.id)
            }
            #expect(fixture.vault.read(accountID: target.id) == nil)
            let home = await reopened.profileHome(id: target.id)
            #expect(FileManager.default.fileExists(atPath: home.appending(path: "credential-operation/auth.json").path))
        } else {
            _ = try await reopened.profile(id: target.id)
            #expect(fixture.vault.read(accountID: target.id) == fixture.credential("b"))
        }
        #expect(try Data(contentsOf: fixture.liveAuth) == fixture.credential("a"))
    }



    @Test func pendingWorkspaceCanRestoreAMissingBackupWithoutChangingActiveLogin() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        let target = accounts[1]
        let renewed = fixture.credential("b", variant: "pending-recovery")
        await #expect(throws: CancellationError.self) {
            try await fixture.store.withSavedCredentialHome(id: target.id, operation: { home in
                try renewed.write(to: home.appending(path: "auth.json"))
            }, stop: { _ in throw CancellationError() })
        }
        try fixture.vault.remove(accountID: target.id)
        let reopened = AccountStore(baseURL: await fixture.store.baseURL, activeHomeURL: fixture.activeHome,
                                    backupVault: fixture.vault, legacyBackupVault: MemoryCredentialVault())
        _ = try await reopened.profile(id: target.id)
        #expect(fixture.vault.read(accountID: target.id) == renewed)
        #expect(try Data(contentsOf: fixture.liveAuth) == fixture.credential("a"))
    }

    @Test func missingTargetBackupIsReportedBeforeClosingCodex() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        try fixture.vault.remove(accountID: accounts[1].id)
        let desktop = CloseCountingDesktop()
        let service = SwitchService(desktop: desktop, store: fixture.store, codex: CredentialIdentity())
        await #expect(throws: OperationError.self) { try await service.switchAccount(to: accounts[1].id) }
        #expect(await desktop.closeCount == 0)
        #expect(try Data(contentsOf: fixture.liveAuth) == fixture.credential("a"))
    }

    @Test func migrationCannotReportSuccessWhenBothVaultsAreMissingCredentials() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        try fixture.vault.remove(accountID: accounts[1].id)
        let reopened = AccountStore(baseURL: await fixture.store.baseURL, activeHomeURL: fixture.activeHome,
                                    backupVault: fixture.vault, legacyBackupVault: MemoryCredentialVault())
        await #expect(throws: AccountStoreError.self) {
            try await reopened.migrateKeychainCredentials()
        }
    }


    @Test(arguments: [false, true])
    func threeAccountsReuseOneHistoryAndKeepOnlyActiveCredentialOnDisk(afterDirectoryMigration: Bool) async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }

        let accounts = try await fixture.registerThreeAccounts()
        let historyURL = fixture.activeHome.appending(path: "session_index.jsonl")
        let history = Data("fixture-thread-id\n".utf8)
        try history.write(to: historyURL)
        let store: AccountStore
        if afterDirectoryMigration {
            store = AccountStore(
                baseURL: fixture.root.appending(path: "local.gptswap"),
                legacyBaseURL: await fixture.store.baseURL,
                activeHomeURL: fixture.activeHome,
                backupVault: fixture.vault
            )
        } else {
            store = fixture.store
        }
        let service = SwitchService(desktop: IsolatedDesktop(), store: store, codex: CredentialIdentity())

        for profile in [accounts[1], accounts[2], accounts[0]] {
            try await service.switchAccount(to: profile.id)
            #expect(try await store.loadRegistry().activeAccountID == profile.id)
            #expect(try Data(contentsOf: historyURL) == history)
            #expect(try Data(contentsOf: fixture.liveAuth) == fixture.vault.read(accountID: profile.id))
        }

        for profile in accounts {
            let home = await store.profileHome(id: profile.id)
            #expect(!FileManager.default.fileExists(atPath: home.appending(path: "auth.json").path))
            #expect(fixture.vault.read(accountID: profile.id) != nil)
        }
    }

    @Test func temporaryCredentialsArePrivateAndRefreshIsCommittedAfterOperationStops() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        let target = accounts[1]
        let expected = fixture.credential("b")
        let renewed = fixture.credential("b", variant: "updated-fixture")

        let temporaryHome = try await fixture.store.withSavedCredentialHome(id: target.id) { home in
            let file = home.appending(path: "auth.json")
            #expect(try Data(contentsOf: file) == expected)
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
            try renewed.write(to: file)
            return home
        }

        #expect(fixture.vault.read(accountID: target.id) == renewed)
        #expect(!FileManager.default.fileExists(atPath: temporaryHome.path))
        #expect(try Data(contentsOf: fixture.liveAuth) == fixture.credential("a"))
    }

    @Test func wrongVaultIdentityCannotReplaceTheActiveLogin() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        fixture.vault.write(fixture.credential("c"), accountID: accounts[1].id)
        let service = SwitchService(desktop: IsolatedDesktop(), store: fixture.store, codex: CredentialIdentity())
        await #expect(throws: OperationError.self) { try await service.switchAccount(to: accounts[1].id) }
        #expect(try Data(contentsOf: fixture.liveAuth) == fixture.credential("a"))
        #expect(try await fixture.store.loadRegistry().activeAccountID == accounts[0].id)
    }

    @Test func startupRecoversAValidPendingRefreshAndRemovesItsTemporaryFiles() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        let target = accounts[1]
        let renewed = fixture.credential("b", variant: "recovery-test")

        await #expect(throws: CancellationError.self) {
            try await fixture.store.withSavedCredentialHome(id: target.id, operation: { home in
                try renewed.write(to: home.appending(path: "auth.json"))
            }, stop: { _ in throw CancellationError() })
        }
        #expect(fixture.vault.read(accountID: target.id) == fixture.credential("b"))

        let reopened = AccountStore(baseURL: await fixture.store.baseURL, activeHomeURL: fixture.activeHome,
                                    backupVault: fixture.vault)
        _ = try await reopened.loadRegistry()
        #expect(fixture.vault.read(accountID: target.id) == renewed)
        let home = await reopened.profileHome(id: target.id).appending(path: "credential-operation")
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test func migrationVerifiesLegacyCredentialAndLeavesFileForAuthorizedCleanup() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let base = await fixture.store.baseURL
        let previous = AccountStore(baseURL: base, activeHomeURL: fixture.activeHome)
        let bytes = fixture.credential("a")
        try bytes.write(to: fixture.liveAuth)
        let oldProfile = try #require(try await previous.syncActiveCredential().accounts.first)
        let oldFile = await previous.profileHome(id: oldProfile.id).appending(path: "auth.json")

        let migrated = try await fixture.store.loadRegistry()
        #expect(migrated.activeAccountID == oldProfile.id)
        #expect(fixture.vault.read(accountID: oldProfile.id) == bytes)
        #expect(try Data(contentsOf: oldFile) == bytes)
        #expect(try Data(contentsOf: fixture.liveAuth) == bytes)
    }

    @Test func backupRemovalCanRetryAfterKeychainDenial() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        let (active, target, other) = (accounts[0], accounts[1], accounts[2])
        let targetHome = await fixture.store.profileHome(id: target.id)
        let history = fixture.activeHome.appending(path: "session_index.jsonl")
        let historyBytes = Data("fixture-thread".utf8)
        try historyBytes.write(to: history)

        fixture.vault.denyNextRemoval()
        await #expect(throws: MemoryCredentialVault.RemovalDenied.self) {
            try await fixture.store.removeAccount(id: target.id)
        }
        #expect(try await fixture.store.loadRegistry().accounts == accounts)
        #expect(FileManager.default.fileExists(atPath: targetHome.path))

        let reopened = AccountStore(baseURL: await fixture.store.baseURL, activeHomeURL: fixture.activeHome,
                                    backupVault: fixture.vault)
        try await reopened.removeAccount(id: target.id)
        try await reopened.removeAccount(id: target.id)
        let remaining = try await reopened.loadRegistry()
        #expect(remaining.activeAccountID == active.id)
        #expect(remaining.accounts.map(\.id) == [active.id, other.id])
        #expect(fixture.vault.read(accountID: target.id) == nil)
        #expect(fixture.vault.read(accountID: other.id) == fixture.credential("c"))
        #expect(try Data(contentsOf: fixture.liveAuth) == fixture.credential("a"))
        #expect(try Data(contentsOf: history) == historyBytes)
    }

    @Test func backupRemovalCanRetryAfterOldVersionAlreadyRemovedDirectory() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        let target = accounts[1]
        let home = await fixture.store.profileHome(id: target.id)
        try FileManager.default.removeItem(at: home)

        try await fixture.store.removeAccount(id: target.id)
        #expect(try await fixture.store.loadRegistry().accounts.map(\.id) == [accounts[0].id, accounts[2].id])
        #expect(fixture.vault.read(accountID: target.id) == nil)
    }

    @Test func interruptedRemovalDoesNotReimportStagedLegacyLogin() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        let target = accounts[1]
        let profile = await fixture.store.profileHome(id: target.id)
        let staged = profile.deletingLastPathComponent().appending(path: ".removing-\(target.id.uuidString)")
        try fixture.credential("b").write(to: profile.appending(path: "auth.json"))
        try FileManager.default.moveItem(at: profile, to: staged)
        await #expect(throws: AccountStoreError.accountRemovalPending) {
            try await fixture.store.activateTargetCredential(id: target.id)
        }
        #expect(try Data(contentsOf: fixture.liveAuth) == fixture.credential("a"))
        try fixture.vault.remove(accountID: target.id)

        let reopened = AccountStore(baseURL: await fixture.store.baseURL, activeHomeURL: fixture.activeHome,
                                    backupVault: fixture.vault)
        #expect(try await reopened.loadRegistry().accounts.map(\.id) == accounts.map(\.id))
        #expect(fixture.vault.read(accountID: target.id) == nil)
        try await reopened.removeAccount(id: target.id)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: fixture.liveAuth) == fixture.credential("a"))
    }

    @Test func failedTargetLaunchRestoresSignedOutStateAndPreviousRegistry() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let accounts = try await fixture.registerThreeAccounts()
        try FileManager.default.removeItem(at: fixture.liveAuth)
        let original = try await fixture.store.syncActiveCredential()
        #expect(original.activeAccountID == nil)

        let desktop = FailFirstLaunchDesktop()
        let service = SwitchService(desktop: desktop, store: fixture.store, codex: CredentialIdentity())
        await #expect(throws: OperationError.self) { try await service.switchAccount(to: accounts[1].id) }
        #expect(try await fixture.store.loadRegistry() == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.liveAuth.path))
        #expect(await desktop.reopenAttempts == 2)
    }

    @Test func vaultFailureDoesNotCreateAPlaintextBackupOrChangeTheLiveLogin() async throws {
        let fixture = try PersonalStoreFixture()
        defer { fixture.remove() }
        let bytes = fixture.credential("a")
        try bytes.write(to: fixture.liveAuth)
        let support = fixture.root.appending(path: "denied-support")
        let protectedStore = AccountStore(baseURL: support, activeHomeURL: fixture.activeHome,
                                          backupVault: DeniedCredentialVault())
        await #expect(throws: DeniedCredentialVault.Failure.self) { try await protectedStore.syncActiveCredential() }
        #expect(try Data(contentsOf: fixture.liveAuth) == bytes)
        let saved = FileManager.default.enumerator(atPath: support.path)?.allObjects as? [String]
        #expect(saved?.contains(where: { $0.hasSuffix("auth.json") }) == false)
    }
}

private actor FailFirstLaunchDesktop: DesktopControlling {
    struct LaunchFailure: Error {}
    private(set) var reopenAttempts = 0

    func closeDesktop() async throws {}

    func reopenDesktop() async throws {
        reopenAttempts += 1
        if reopenAttempts == 1 { throw LaunchFailure() }
    }
}

private struct IsolatedDesktop: DesktopControlling {
    func closeDesktop() async throws {}
    func reopenDesktop() async throws {}
}

private final class MemoryCredentialVault: BackupCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    struct RemovalDenied: Error {}
    private var items: [UUID: Data] = [:]
    private var deniesRemoval = false

    func read(accountID: UUID) -> Data? { lock.withLock { items[accountID] } }
    func write(_ credential: Data, accountID: UUID) { lock.withLock { items[accountID] = credential } }
    func denyNextRemoval() { lock.withLock { deniesRemoval = true } }

    func remove(accountID: UUID) throws {
        try lock.withLock {
            if deniesRemoval {
                deniesRemoval = false
                throw RemovalDenied()
            }
            items[accountID] = nil
        }
    }
}

private struct DeniedCredentialVault: BackupCredentialVault {
    struct Failure: Error {}

    func read(accountID: UUID) -> Data? { nil }
    func write(_ credential: Data, accountID: UUID) throws { throw Failure() }
    func remove(accountID: UUID) {}
}

private struct PersonalStoreFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "switcher-personal-test-\(UUID())")
    let vault = MemoryCredentialVault()
    let activeHome: URL
    let store: AccountStore

    var liveAuth: URL { activeHome.appending(path: "auth.json") }

    init() throws {
        activeHome = root.appending(path: "active")
        try FileManager.default.createDirectory(at: activeHome, withIntermediateDirectories: true)
        store = AccountStore(baseURL: root.appending(path: "support"), activeHomeURL: activeHome, backupVault: vault)
    }

    func registerThreeAccounts() async throws -> [AccountProfile] {
        try credential("a").write(to: liveAuth)
        let active = try #require(try await store.syncActiveCredential().accounts.first)
        var profiles = [active]
        for id in ["b", "c"] {
            let profile = AccountProfile(id: UUID(), displayName: id, email: nil, accountID: id,
                                         createdAt: Date(), lastUsedAt: nil)
            let home = try await store.createProfileDirectory(id: profile.id)
            try credential(id).write(to: home.appending(path: "auth.json"))
            try await store.addProfile(profile)
            profiles.append(profile)
        }
        return profiles
    }

    func credential(_ id: String, variant: String = "fixture") -> Data {
        Data(#"{"tokens":{"account_id":"\#(id)","refresh_token":"\#(variant)"}}"#.utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor CloseCountingDesktop: DesktopControlling {
    private(set) var closeCount = 0
    func closeDesktop() { closeCount += 1 }
    func reopenDesktop() {}
}
