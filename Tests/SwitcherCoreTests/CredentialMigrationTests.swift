import Foundation
import Testing
@testable import SwitcherCore

struct CredentialMigrationTests {
    @Test func migrationIsManualAndLeavesSettingsAndConversationBytesUntouched() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try await fixture.saveOldAccounts()
        let settings = AppSettings(language: .simplifiedChinese)
        try await fixture.oldStore.saveSettings(settings)
        let conversation = fixture.activeHome.appending(path: "session_index.jsonl")
        let conversationBytes = Data("test-thread-101".utf8)
        try conversationBytes.write(to: conversation)
        let accounts = try await fixture.oldStore.loadRegistry()
        let credentials = try fixture.profiles.map { try fixture.oldVault.read(accountID: $0.id) }

        let upgraded = fixture.upgradedStore()
        #expect(try await upgraded.loadRegistry() == accounts)
        #expect(fixture.newVault.count == 0)
        #expect(try await upgraded.migrateKeychainCredentials() == 3)
        #expect(try await upgraded.migrateKeychainCredentials() == 0)
        #expect(try fixture.profiles.map { try fixture.newVault.read(accountID: $0.id) } == credentials)
        #expect(try fixture.profiles.map { try fixture.oldVault.read(accountID: $0.id) } == credentials)
        #expect(try await upgraded.loadSettings() == settings)
        #expect(try Data(contentsOf: conversation) == conversationBytes)
    }

    @Test func upgradedRegistryRemainsVisibleBeforeMigratingAnInterruptedRefresh() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try await fixture.saveOldAccounts()
        let profile = fixture.profiles[0]
        let pending = try await fixture.interruptRefresh(for: profile)
        let registry = try await fixture.oldStore.loadRegistry()

        let upgraded = fixture.upgradedStore()
        #expect(try await upgraded.loadRegistry() == registry)
        #expect(fixture.newVault.count == 0)
        #expect(try Data(contentsOf: pending.auth) == pending.bytes)

        #expect(try await upgraded.migrateKeychainCredentials() == 3)
        #expect(try fixture.newVault.read(accountID: profile.id) == pending.bytes)
        #expect(try fixture.oldVault.read(accountID: profile.id) == fixture.credential(for: profile))
        #expect(!FileManager.default.fileExists(atPath: pending.auth.path))
    }

    @Test func failedLoginCleanupIsIndependentOfPendingRegisteredCredentials() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try await fixture.saveOldAccounts()
        let pending = try await fixture.interruptRefresh(for: fixture.profiles[0])
        let upgraded = fixture.upgradedStore()
        let unregistered = UUID()
        let directory = try await upgraded.beginAccountLogin(id: unregistered)
        try Data("test-incomplete-login".utf8).write(to: directory.appending(path: "auth.json"))
        fixture.newVault.setReadFailure(for: fixture.profiles[0].id)

        try await upgraded.discardUnregisteredProfile(id: unregistered)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try Data(contentsOf: pending.auth) == pending.bytes)
        #expect(fixture.newVault.count == 0)
    }

    @Test func partiallyMigratedAccountsCanRetryWithoutOverwritingTheNewerLogin() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try await fixture.saveOldAccounts()
        let upgraded = fixture.upgradedStore()
        let firstID = fixture.profiles[0].id
        let secondID = fixture.profiles[1].id
        fixture.oldVault.setReadFailure(for: secondID)
        await #expect(throws: MigrationVault.AccessDenied.self) {
            try await upgraded.migrateKeychainCredentials()
        }
        #expect(fixture.newVault.count == 1)
        let newest = try fixture.credential(for: fixture.profiles[0], variant: "newer-test-token")
        try fixture.newVault.write(newest, accountID: firstID)
        fixture.oldVault.setReadFailure(for: firstID)
        #expect(try await upgraded.migrateKeychainCredentials() == 2)
        #expect(try fixture.newVault.read(accountID: firstID) == newest)
    }

    @Test func wrongLegacyIdentityCannotPopulateTheNewService() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try await fixture.saveOldAccounts()
        let other = try fixture.credential(for: fixture.profiles[1])
        let id = fixture.profiles[0].id
        try fixture.oldVault.write(other, accountID: id)
        await #expect(throws: AccountStoreError.activeCredentialMismatch) {
            try await fixture.upgradedStore().migrateKeychainCredentials()
        }
        #expect(try fixture.oldVault.read(accountID: id) == other)
        #expect(fixture.newVault.count == 0)
    }

    @Test func removedAccountCannotBeRestoredByRerunningMigration() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try await fixture.saveOldAccounts()
        let upgraded = fixture.upgradedStore()
        let id = fixture.profiles[0].id
        #expect(try await upgraded.migrateKeychainCredentials() == 3)
        try await upgraded.removeAccount(id: id)
        #expect(try fixture.oldVault.read(accountID: id) == nil)
        #expect(try fixture.newVault.read(accountID: id) == nil)
        let reopened = fixture.upgradedStore()
        #expect(try await reopened.migrateKeychainCredentials() == 0)
        #expect(try await reopened.loadRegistry().accounts.count == 2)
    }

    @Test func newInstallationNeedsNoLegacyData() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let upgraded = fixture.upgradedStore()
        #expect(try await upgraded.migrateKeychainCredentials() == 0)
        #expect(fixture.newVault.count == 0)
    }
}

private struct MigrationFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let oldVault = MigrationVault()
    let newVault = MigrationVault()
    let profiles = (1...3).map { index in
        AccountProfile(
            id: UUID(), displayName: "Test \(index)", email: nil, accountID: "migration-fixture-\(index)",
            createdAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil
        )
    }

    let oldStore: AccountStore
    let activeHome: URL
    let storeHome: URL

    init() throws {
        activeHome = root.appending(path: "active")
        storeHome = root.appending(path: "store")
        try FileManager.default.createDirectory(at: activeHome, withIntermediateDirectories: true)
        oldStore = AccountStore(baseURL: storeHome, activeHomeURL: activeHome, backupVault: oldVault)
    }

    func upgradedStore() -> AccountStore {
        AccountStore(
            baseURL: storeHome, activeHomeURL: activeHome,
            backupVault: newVault, legacyBackupVault: oldVault
        )
    }

    func saveOldAccounts() async throws {
        for profile in profiles {
            let directory = try await oldStore.createProfileDirectory(id: profile.id)
            try credential(for: profile).write(to: directory.appending(path: "auth.json"))
            try await oldStore.addProfile(profile)
        }
    }

    private enum FixtureStop: Error { case interrupted }

    func interruptRefresh(for profile: AccountProfile) async throws -> (auth: URL, bytes: Data) {
        let bytes = try credential(for: profile, variant: "refresh-before-upgrade")
        let profileHome = await oldStore.profileHome(id: profile.id)
        let auth = profileHome.appending(path: "credential-operation/auth.json")
        await #expect(throws: FixtureStop.interrupted) {
            try await oldStore.withSavedCredentialHome(id: profile.id, operation: { workspace in
                try bytes.write(to: workspace.appending(path: "auth.json"))
            }, stop: { _ in throw FixtureStop.interrupted })
        }
        return (auth, bytes)
    }

    func credential(for profile: AccountProfile, variant: String = "old-test-token") throws -> Data {
        try TestAuthFixture.authJSON(accountID: profile.accountID, accessToken: variant)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class MigrationVault: BackupCredentialVault, @unchecked Sendable {
    struct AccessDenied: Error {}
    private let lock = NSLock()
    private var items: [UUID: Data] = [:]
    private var rejectedRead: UUID?

    var count: Int { lock.withLock { items.count } }

    func setReadFailure(for id: UUID) { lock.withLock { rejectedRead = id } }

    func read(accountID: UUID) throws -> Data? {
        try lock.withLock {
            if rejectedRead == accountID { throw AccessDenied() }
            return items[accountID]
        }
    }

    func write(_ credential: Data, accountID: UUID) throws {
        lock.withLock { items[accountID] = credential }
    }

    func remove(accountID: UUID) throws { lock.withLock { items[accountID] = nil } }
}
