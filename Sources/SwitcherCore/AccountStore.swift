import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(Windows)
import SwitcherPlatform
#endif

public protocol AccountStoring: Sendable {
    func loadRegistry() async throws -> AccountRegistry
    func profile(id: UUID) async throws -> AccountProfile
    func activeCredentialExists() async -> Bool
    func clearActiveCredential() async throws
    func activeCodexHome() async -> URL
    func saveCurrentCredential() async throws
    func activateTargetCredential(id: UUID) async throws
    func restoreActiveCredential(id: UUID) async throws
    func commitActiveAccountID(_ id: UUID) async throws
    func restoreActiveSelection(from original: AccountRegistry, replacing targetID: UUID) async throws
}

public actor AccountStore: AccountStoring {
    public let baseURL: URL
    public let activeHomeURL: URL

    private let fileManager: FileManager
    private let legacyBaseURL: URL?
    private let backupVault: (any BackupCredentialVault)?
    private let legacyBackupVault: (any BackupCredentialVault)?

    public nonisolated var supportsCredentialMigration: Bool { backupVault != nil && legacyBackupVault != nil }
    private var registry: AccountRegistry?
    private var usageCache: UsageCache?

    public init(
        baseURL: URL? = nil,
        legacyBaseURL: URL? = nil,
        activeHomeURL: URL? = nil,
        fileManager: FileManager = .default,
        backupVault: (any BackupCredentialVault)? = nil,
        legacyBackupVault: (any BackupCredentialVault)? = nil
    ) {
        self.fileManager = fileManager
        self.backupVault = backupVault
        self.legacyBackupVault = legacyBackupVault
        #if os(Windows)
        let applicationSupportURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local").path)
        #else
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        #endif
        if let baseURL {
            self.baseURL = baseURL
            self.legacyBaseURL = legacyBaseURL
        } else {
            self.baseURL = applicationSupportURL.appending(
                path: "local.gptswap",
                directoryHint: .isDirectory
            )
            self.legacyBaseURL = nil
        }
        self.activeHomeURL = activeHomeURL
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
    }

    private var accountsURL: URL { baseURL.appending(path: "accounts.json") }
    private var settingsURL: URL { baseURL.appending(path: "settings.json") }
    private var subscriptionCacheURL: URL { baseURL.appending(path: "subscription-cache.json") }
    private var usageCacheURL: URL { baseURL.appending(path: "usage-cache.json") }
    private var profilesURL: URL { baseURL.appending(path: "accounts", directoryHint: .isDirectory) }
    private var legacyResetLogURL: URL { baseURL.appending(path: "reset-expiry-experiment.jsonl") }
    public nonisolated var resetExpiryLogURL: URL { baseURL.appending(path: "auto-reset.jsonl") }

    func loadResetExpiryLog() throws -> [ResetExpiryEvent] {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: resetExpiryLogURL.path) else { return [] }
        // Skip partial or damaged trailing lines rather than permanently bricking automation.
        return try readChecked(resetExpiryLogURL).split(separator: 0x0A).compactMap { line in
            try? Self.decoder.decode(ResetExpiryEvent.self, from: Data(line))
        }
    }

    func appendResetExpiryLog(_ events: [ResetExpiryEvent]) throws {
        guard !events.isEmpty else { return }
        try prepareDirectories()
        try checkPath(resetExpiryLogURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        if fileManager.fileExists(atPath: resetExpiryLogURL.path),
           let size = (try? fileManager.attributesOfItem(atPath: resetExpiryLogURL.path)[.size] as? NSNumber)?.intValue,
           size > 262_144 {
            let existing = (try? loadResetExpiryLog()) ?? []
            let compacted = AutoReset.compactedHistory(existing + events)
            try writeResetLog(compacted, using: encoder)
            return
        }

        if !fileManager.fileExists(atPath: resetExpiryLogURL.path) {
            try secureAtomicWrite(Data(), to: resetExpiryLogURL)
        }
        try restrictPermissions(resetExpiryLogURL, directory: false)
        var bytes = Data()
        for event in events {
            bytes.append(try encoder.encode(event))
            bytes.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: resetExpiryLogURL)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
    }

    private func writeResetLog(_ events: [ResetExpiryEvent], using encoder: JSONEncoder) throws {
        var bytes = Data()
        for event in events {
            bytes.append(try encoder.encode(event))
            bytes.append(0x0A)
        }
        try secureAtomicWrite(bytes, to: resetExpiryLogURL)
    }

    public func loadRegistry() throws -> AccountRegistry {
        try prepareDirectories()
        if let registry { return registry }
        guard var loaded = try readRegistryFile() else {
            #if os(macOS)
            if backupVault != nil { try recoverInterruptedLogins(accounts: []) }
            #endif
            registry = .empty
            return .empty
        }
        var changed = false
        for index in loaded.accounts.indices {
            let profile = loaded.accounts[index]
            if backupVault != nil,
               !(backupVault is any ConsolidatingBackupCredentialVault) || profile.accountID == nil {
                try migrateBackupIfNeeded(profile)
            }
            if profile.accountID == nil,
               let data = try readSavedBackup(id: profile.id),
               let identity = try CredentialIdentity.decode(data) {
                if let expected = profile.email, let actual = identity.email,
                   expected.caseInsensitiveCompare(actual) != .orderedSame {
                    throw AccountStoreError.activeCredentialMismatch
                }
                loaded.accounts[index].accountID = identity.accountID
                changed = true
            }
        }
        #if os(macOS)
        if backupVault != nil {
            // An upgraded account may not have a backup in the new service yet.
            // Its pending refresh belongs to migration or to a per-account operation.
            if !supportsCredentialMigration && !(backupVault is any ConsolidatingBackupCredentialVault) {
                for profile in loaded.accounts { try recoverPendingCredentials(profile) }
            }
            try recoverInterruptedLogins(accounts: loaded.accounts)
        }
        #endif
        if changed { try saveRegistry(loaded) }
        registry = loaded
        return loaded
    }

    private func readRegistryFile() throws -> AccountRegistry? {
        guard fileManager.fileExists(atPath: accountsURL.path) else { return nil }
        return try Self.decoder.decode(AccountRegistry.self, from: readChecked(accountsURL))
    }

    public func migrateKeychainCredentials() throws -> Int {
        guard let backupVault, let legacyBackupVault else { return 0 }
        // Read the saved list without starting ordinary vault recovery first.
        try prepareDirectories()
        let profiles = try readRegistryFile()?.accounts ?? []
        var migrated = 0
        for profile in profiles {
            let id = profile.id
            guard try !removalDirectoryExists(stagedRemovalDirectory(id: id)) else { continue }
            if let existing = try backupVault.read(accountID: id) {
                try validateSavedIdentity(existing, profile: profile)
                continue
            }
            #if os(macOS)
            try recoverPendingCredentials(profile)
            if let recovered = try backupVault.read(accountID: id) {
                try validateSavedIdentity(recovered, profile: profile)
                migrated += 1
                continue
            }
            #endif
            guard let legacy = try legacyBackupVault.read(accountID: id) else {
                throw AccountStoreError.targetCredentialMissing
            }
            try validateSavedIdentity(legacy, profile: profile)
            let added = try backupVault.addIfAbsent(legacy, accountID: id)
            guard let stored = try backupVault.read(accountID: id), !added || stored == legacy else {
                throw AccountStoreError.targetCredentialMissing
            }
            try validateSavedIdentity(stored, profile: profile)
            if added {
                #if os(macOS)
                try recoverPendingCredentials(profile)
                #endif
                migrated += 1
            }
        }
        return migrated
    }

    public func loadSettings() throws -> AppSettings {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: settingsURL.path) else { return .default }
        return try Self.decoder.decode(AppSettings.self, from: readChecked(settingsURL))
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try prepareDirectories()
        try writeJSON(settings, to: settingsURL)
    }

    public func updateSettings(_ mutate: @Sendable (inout AppSettings) -> Void) throws -> AppSettings {
        var updated = try loadSettings()
        mutate(&updated)
        try saveSettings(updated)
        return updated
    }

    public func loadUsageCache() throws -> UsageCache {
        try prepareDirectories()
        if let usageCache { return usageCache }
        guard fileManager.fileExists(atPath: usageCacheURL.path) else {
            usageCache = .empty
            return .empty
        }
        let loaded = try Self.decoder.decode(UsageCache.self, from: readChecked(usageCacheURL))
        usageCache = loaded
        return loaded
    }

    public func cacheWeeklyUsage(_ usage: WeeklyUsage, profileID: UUID, fetchedAt: Date = Date()) throws {
        try cacheWeeklyUsage([UsageCacheEntry(profileID: profileID, usage: usage, fetchedAt: fetchedAt)])
    }

    public func cacheWeeklyUsage(_ entries: [UsageCacheEntry]) throws {
        guard !entries.isEmpty else { return }
        let registry = try loadRegistry()
        let accountIDs = Set(registry.accounts.map(\.id))
        var cache = try loadUsageCache()
        var changed = false
        for entry in entries where accountIDs.contains(entry.profileID) {
            // Keep this cache readable by older builds that require both weekly fields.
            guard entry.usage.remainingPercent != nil, entry.usage.resetsAt != nil else { continue }
            if let index = cache.entries.firstIndex(where: { $0.profileID == entry.profileID }) {
                cache.entries[index] = entry
            } else {
                cache.entries.append(entry)
            }
            changed = true
        }
        if changed { try saveUsageCache(cache) }
    }

    private struct SubscriptionCacheEntry: Codable {
        let profileID: UUID
        let accountID: String
        let value: LiveSubscription
    }

    private func readSubscriptionCache() throws -> [SubscriptionCacheEntry] {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: subscriptionCacheURL.path) else { return [] }
        return try Self.decoder.decode([SubscriptionCacheEntry].self, from: readChecked(subscriptionCacheURL))
    }

    public func loadLiveSubscriptions() throws -> [UUID: LiveSubscription] {
        let registry = try loadRegistry()
        var result: [UUID: LiveSubscription] = [:]
        for entry in try readSubscriptionCache() {
            guard registry.accounts.contains(where: {
                $0.id == entry.profileID && $0.accountID == entry.accountID
            }) else { continue }
            result[entry.profileID] = entry.value
        }
        return result
    }

    public func cacheLiveSubscription(_ value: LiveSubscription, profile: AccountProfile) throws {
        let registry = try loadRegistry()
        guard let accountID = profile.accountID, !accountID.isEmpty,
              registry.accounts.contains(where: { $0.id == profile.id && $0.accountID == accountID }) else { return }
        // A corrupt derived cache must not prevent a fresh service result from
        // recovering it. The source credentials and registry are never changed.
        var entries = (try? readSubscriptionCache()) ?? []
        entries.removeAll { entry in
            entry.profileID == profile.id || !registry.accounts.contains(where: {
                $0.id == entry.profileID && $0.accountID == entry.accountID
            })
        }
        entries.append(SubscriptionCacheEntry(profileID: profile.id, accountID: accountID, value: value))
        try writeJSON(entries, to: subscriptionCacheURL)
    }

    public func subscriptionCredential(profile: AccountProfile, isActive: Bool) throws -> Data {
        let (_, bytes) = try readVerifiedSubscriptionCredential(profile: profile, isActive: isActive)
        return bytes
    }

    func parsedSubscriptionCredential(profile: AccountProfile, isActive: Bool) throws -> ParsedCredential {
        let (parsed, _) = try readVerifiedSubscriptionCredential(profile: profile, isActive: isActive)
        return parsed
    }

    private func readVerifiedSubscriptionCredential(
        profile: AccountProfile,
        isActive: Bool
    ) throws -> (parsed: ParsedCredential, bytes: Data) {
        let bytes = try isActive ? readChecked(activeHomeURL.appending(path: "auth.json"))
            : requireSavedBackup(id: profile.id)
        guard bytes.count <= ParsedCredential.maximumCredentialBytes else {
            throw AccountStoreError.activeCredentialMismatch
        }
        let parsed: ParsedCredential
        do {
            parsed = try ParsedCredential.decode(bytes)
        } catch {
            throw CodexClientError.identityUnavailable
        }
        guard let identity = parsed.localIdentity, identity.matches(profile) else {
            throw AccountStoreError.activeCredentialMismatch
        }
        return (parsed, bytes)
    }

    public func permitsSubscriptionCredentialRenewal(profile: AccountProfile) throws -> Bool {
        _ = try parsedSubscriptionCredential(profile: profile, isActive: false)
        guard activeCredentialExists() else { return true }
        guard let current = try CredentialIdentity.decode(readChecked(activeHomeURL.appending(path: "auth.json"))) else { return false }
        if current.accountID == profile.accountID { return false }
        if let email = current.email, let expected = profile.email,
           email.caseInsensitiveCompare(expected) == .orderedSame { return false }
        return true
    }

    public func profile(id: UUID) throws -> AccountProfile {
        let registry = try loadRegistry()
        guard let profile = registry.accounts.first(where: { $0.id == id }) else {
            throw AccountStoreError.profileNotFound
        }
        #if os(macOS)
        if backupVault != nil {
            guard try !removalDirectoryExists(stagedRemovalDirectory(id: id)) else {
                throw AccountStoreError.accountRemovalPending
            }
            if backupVault is any ConsolidatingBackupCredentialVault { try migrateBackupIfNeeded(profile) }
            try recoverPendingCredentials(profile)
            try validateSavedIdentity(requireSavedBackup(id: id), profile: profile)
        }
        #endif
        return profile
    }

    public func profileHome(id: UUID) -> URL {
        profilesURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func withSavedCredentialHome<Value: Sendable>(
        id: UUID, operation: @Sendable (URL) async throws -> Value,
        stop: @Sendable (URL) async throws -> Void = { _ in }
    ) async throws -> Value {
        let directory = profileHome(id: id)
        #if os(macOS)
        if backupVault != nil {
            let profile = try profile(id: id)
            let workspace = try CredentialWorkspace(profileHome: directory)
            defer { workspace.release() }
            try recoverPendingCredential(in: workspace, profile: profile)
            let original = try requireSavedBackup(id: id)
            try validateSavedIdentity(original, profile: profile)
            try workspace.prepare(for: original, fileManager: fileManager)
            try secureAtomicWrite(original, to: workspace.authFile)

            let result: Result<Value, any Error>
            do { result = .success(try await operation(workspace.home)) }
            catch { result = .failure(error) }
            try await stop(workspace.home)
            try recoverPendingCredential(in: workspace, profile: profile)
            return try result.get()
        }
        #endif
        return try await operation(directory)
    }

    #if os(macOS)
    private func recoverPendingCredential(in workspace: CredentialWorkspace, profile: AccountProfile) throws {
        guard fileManager.fileExists(atPath: workspace.home.path) else { return }
        let current = try readSavedBackup(id: profile.id)
        if let new = try workspace.pendingReplacement(current: current, fileManager: fileManager) {
            try validateSavedIdentity(new, profile: profile)
            if let backupVault, current == nil {
                _ = try backupVault.addIfAbsent(new, accountID: profile.id)
            } else {
                try writeSavedBackup(new, id: profile.id)
            }
            guard try requireSavedBackup(id: profile.id) == new else { throw AccountStoreError.targetCredentialMissing }
        }
        try workspace.clean(fileManager: fileManager)
    }

    private func recoverPendingCredentials(_ profile: AccountProfile) throws {
        let directory = profileHome(id: profile.id)
        guard fileManager.fileExists(atPath: directory.appending(path: "credential-operation").path) else { return }
        let workspace = try CredentialWorkspace(profileHome: directory)
        defer { workspace.release() }
        try recoverPendingCredential(in: workspace, profile: profile)
    }
    #endif

    public func readSubscriptionSnapshot(profile: AccountProfile, isActive: Bool) -> SubscriptionSnapshot? {
        func snapshot(_ credential: Data?) -> SubscriptionSnapshot? {
            guard let credential else { return nil }
            return SubscriptionSnapshotReader.read(
                credential: credential,
                expectedAccountID: profile.accountID,
                expectedEmail: profile.email
            )
        }

        let saved = snapshot(try? readSavedBackup(id: profile.id))
        guard isActive else { return saved }
        let current = snapshot(try? readChecked(activeHomeURL.appending(path: "auth.json")))
        guard let current else { return saved }
        guard let saved else { return current }
        return current.lastChecked >= saved.lastChecked ? current : saved
    }

    public func activeCodexHome() -> URL { activeHomeURL }

    public func activeCredentialExists() -> Bool {
        fileManager.fileExists(atPath: activeHomeURL.appending(path: "auth.json").path)
    }

    public func createProfileDirectory(id: UUID) throws -> URL {
        try prepareDirectories()
        let directory = profileHome(id: id)
        try checkPath(directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try restrictPermissions(directory, directory: true)
        return directory
    }

    func beginAccountLogin(id: UUID) throws -> URL {
        let directory = try createProfileDirectory(id: id)
        #if os(macOS)
        if backupVault != nil {
            let owner = Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
            try secureAtomicWrite(owner, to: directory.appending(path: "pending-login"))
        }
        #endif
        return directory
    }

    @available(*, deprecated, message: "Use syncActiveCredential or createProfileDirectory and addProfile instead")
    public func importCurrentProfile(_ profile: AccountProfile) throws {
        try seedActiveProfile(profile)
    }

    func seedActiveProfile(_ profile: AccountProfile) throws {
        let source = activeHomeURL.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: source.path) else {
            throw AccountStoreError.activeCredentialMissing
        }
        try importProfile(profile, credential: readChecked(source))
    }

    private func importProfile(_ profile: AccountProfile, credential: Data) throws {
        _ = try createProfileDirectory(id: profile.id)
        try writeSavedBackup(credential, id: profile.id)

        var current = try loadRegistry()
        current.accounts.append(profile)
        current.activeAccountID = profile.id
        try saveRegistry(current)
    }

    public func addProfile(_ profile: AccountProfile) throws {
        let authURL = profileHome(id: profile.id).appending(path: "auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw AccountStoreError.targetCredentialMissing
        }
        try restrictPermissions(authURL, directory: false)
        var current = try loadRegistry()
        let identity = AccountIdentity(accountID: profile.accountID, email: profile.email)
        guard !current.accounts.contains(where: { identity.matches($0) }) else {
            throw AccountStoreError.duplicateAccount
        }
        if let backupVault {
            let bytes = try readChecked(authURL)
            try validateSavedIdentity(bytes, profile: profile)
            try backupVault.write(bytes, accountID: profile.id)
            guard try backupVault.read(accountID: profile.id) == bytes else {
                throw AccountStoreError.targetCredentialMissing
            }
        }
        current.accounts.append(profile)
        try saveRegistry(current)
        if backupVault != nil {
            try fileManager.removeItem(at: authURL)
            let loginMarker = profileHome(id: profile.id).appending(path: "pending-login")
            if fileManager.fileExists(atPath: loginMarker.path) { try fileManager.removeItem(at: loginMarker) }
        }
    }

    public func discardUnregisteredProfile(id: UUID) throws {
        // Clearing an interrupted add only needs the saved registry, not another account's vault.
        guard try readRegistryFile()?.accounts.contains(where: { $0.id == id }) != true else { return }
        let directory = profileHome(id: id)
        if fileManager.fileExists(atPath: directory.path) { try removeProfileDirectory(directory) }
        try backupVault?.remove(accountID: id)
    }

    private func registerActiveIdentity(_ identity: AccountIdentity, credential bytes: Data) throws {
        let current = try loadRegistry()
        if let profile = current.accounts.first(where: { identity.matches($0) }) {
            try saveObservedActiveCredential(bytes, id: profile.id)
            if current.activeAccountID != profile.id { try commitActiveAccountID(profile.id) }
        } else {
            let candidate = AccountProfile(id: UUID(), displayName: identity.suggestedDisplayName,
                email: identity.email, accountID: identity.accountID, createdAt: Date(), lastUsedAt: Date())
            try importProfile(candidate, credential: bytes)
        }
    }

    private func readActiveCredential() throws -> (bytes: Data, identity: AccountIdentity)? {
        guard activeCredentialExists() else { return nil }
        let bytes = try readChecked(activeHomeURL.appending(path: "auth.json"))
        guard let identity = try CredentialIdentity.decode(bytes) else {
            throw CodexClientError.identityUnavailable
        }
        return (bytes, identity)
    }

    private func clearActiveAccountIfMissing() throws -> AccountRegistry {
        var current = try loadRegistry()
        if current.activeAccountID != nil {
            current.activeAccountID = nil
            try saveRegistry(current)
        }
        return current
    }

    /// The live login determines the active profile. Identify and save the same credential bytes.
    public func syncActiveCredential() throws -> AccountRegistry {
        guard let (bytes, identity) = try readActiveCredential() else {
            return try clearActiveAccountIfMissing()
        }
        try registerActiveIdentity(identity, credential: bytes)
        return try loadRegistry()
    }

    /// Stop the matching resident reader before replacing its credential. Recheck
    /// the live login after suspension so a newer Desktop login is never lost.
    public func syncActiveCredential(beforeUpdatingProfile: @Sendable (URL) async throws -> Void) async throws -> AccountRegistry {
        while true {
            let current = try loadRegistry()
            guard let (bytes, identity) = try readActiveCredential() else {
                return try clearActiveAccountIfMissing()
            }
            if let profile = current.accounts.first(where: { identity.matches($0) }) {
                let home = profileHome(id: profile.id)
                if try readSavedBackup(id: profile.id) != bytes {
                    try await beforeUpdatingProfile(home)
                    try Task.checkCancellation()
                    guard activeCredentialExists(),
                          try readChecked(activeHomeURL.appending(path: "auth.json")) == bytes else { continue }
                    let latest = try loadRegistry()
                    guard latest.accounts.first(where: { identity.matches($0) })?.id == profile.id else { continue }
                }
            }
            try registerActiveIdentity(identity, credential: bytes)
            return try loadRegistry()
        }
    }

    public func removeAccount(id: UUID) throws {
        var current = try loadRegistry()
        guard current.activeAccountID != id else {
            throw AccountStoreError.cannotRemoveActiveAccount
        }
        guard current.accounts.contains(where: { $0.id == id }) else { return }

        var cache = try loadUsageCache()
        let subscriptions = fileManager.fileExists(atPath: subscriptionCacheURL.path) ? try readSubscriptionCache() : []
        // Confirm an atomic write of the account list succeeds before discarding credentials.
        try writeJSON(current, to: accountsURL)
        try removeProfileData(id: id)

        if cache.entries.contains(where: { $0.profileID == id }) {
            cache.entries.removeAll(where: { $0.profileID == id })
            try saveUsageCache(cache)
        }
        let retainedSubscriptions = subscriptions.filter { $0.profileID != id }
        if retainedSubscriptions.count != subscriptions.count {
            try writeJSON(retainedSubscriptions, to: subscriptionCacheURL)
        }
        current.accounts.removeAll(where: { $0.id == id })
        try saveRegistry(current)
    }

    private func removeProfileData(id: UUID) throws {
        let profile = profileHome(id: id)
        let hasProfile = try removalDirectoryExists(profile)
        guard let backupVault else {
            if hasProfile { try removeProfileDirectory(profile) }
            return
        }

        // Keep a single copy outside the normal profile path. A restart must not
        // reimport any legacy plaintext file from a deletion in progress.
        let staged = stagedRemovalDirectory(id: id)
        let alreadyStaged = try removalDirectoryExists(staged)
        guard !hasProfile || !alreadyStaged else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: staged.path])
        }
        if hasProfile { try fileManager.moveItem(at: profile, to: staged) }
        do {
            // Remove the old entry first so a retry cannot restore a deleted account.
            try legacyBackupVault?.remove(accountID: id)
            try backupVault.remove(accountID: id)
        } catch {
            if hasProfile {
                try restoreRemovalDirectory(staged: staged, profile: profile, after: error)
            }
            throw error
        }
        if hasProfile || alreadyStaged { try removeProfileDirectory(staged) }
    }

    private func stagedRemovalDirectory(id: UUID) -> URL {
        profilesURL.appending(path: ".removing-\(id.uuidString)", directoryHint: .isDirectory)
    }

    private func removalDirectoryExists(_ directory: URL) throws -> Bool {
        try checkPath(directory)
        do {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: directory.path])
            }
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private func restoreRemovalDirectory(staged: URL, profile: URL, after removalError: any Error) throws {
        do {
            try fileManager.moveItem(at: staged, to: profile)
        } catch {
            throw NSError(domain: "CodexAccountSwitcher.AccountStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(removalError.localizedDescription) Restoring the account folder also failed: \(error.localizedDescription)",
            ])
        }
    }

    public func setAccountNote(id: UUID, note: String) throws -> AccountRegistry {
        var current = try loadRegistry()
        guard let index = current.accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.profileNotFound
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        current.accounts[index].note = trimmed.isEmpty ? nil : trimmed
        try saveRegistry(current)
        return current
    }

    public func moveAccount(id: UUID, to targetID: UUID) throws -> AccountRegistry {
        var current = try loadRegistry()
        guard let source = current.accounts.firstIndex(where: { $0.id == id }),
              let destination = current.accounts.firstIndex(where: { $0.id == targetID }) else {
            throw AccountStoreError.profileNotFound
        }
        guard source != destination else { return current }
        let profile = current.accounts.remove(at: source)
        current.accounts.insert(profile, at: destination)
        try saveRegistry(current)
        return current
    }

    public func saveCurrentCredential() throws {
        let current = try loadRegistry()
        guard let activeID = current.activeAccountID else {
            throw AccountStoreError.activeProfileMissing
        }
        guard let profile = current.accounts.first(where: { $0.id == activeID }) else {
            throw AccountStoreError.activeProfileMissing
        }
        let source = activeHomeURL.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: source.path) else {
            throw AccountStoreError.activeCredentialMissing
        }
        let bytes = try readChecked(source)
        if backupVault != nil { try validateSavedIdentity(bytes, profile: profile) }
        try saveObservedActiveCredential(bytes, id: activeID)
    }

    public func activateTargetCredential(id: UUID) throws {
        try installCredential(id: id)
    }

    public func clearActiveCredential() throws {
        try checkPath(activeHomeURL.appending(path: "auth.json"))
        try fileManager.removeItem(at: activeHomeURL.appending(path: "auth.json"))
    }

    public func restoreActiveCredential(id: UUID) throws {
        try installCredential(id: id)
    }

    private func installCredential(id: UUID) throws {
        let profile = try profile(id: id)
        #if os(macOS)
        if backupVault != nil {
            guard try !removalDirectoryExists(stagedRemovalDirectory(id: id)) else {
                throw AccountStoreError.accountRemovalPending
            }
            try recoverPendingCredentials(profile)
        }
        #endif
        let bytes = try requireSavedBackup(id: id)
        if backupVault != nil { try validateSavedIdentity(bytes, profile: profile) }

        try checkPath(activeHomeURL)
        try fileManager.createDirectory(at: activeHomeURL, withIntermediateDirectories: true)
        let destination = activeHomeURL.appending(path: "auth.json")
        try secureAtomicWrite(bytes, to: destination)
    }

    public func commitActiveAccountID(_ id: UUID) throws {
        var current = try loadRegistry()
        guard let index = current.accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.profileNotFound
        }
        current.activeAccountID = id
        current.accounts[index].lastUsedAt = Date()
        try saveRegistry(current)
    }

    public func restoreActiveSelection(from original: AccountRegistry, replacing targetID: UUID) throws {
        var current = try loadRegistry()
        guard current.activeAccountID == targetID,
              let target = current.accounts.firstIndex(where: { $0.id == targetID }),
              let originalTarget = original.accounts.first(where: { $0.id == targetID }) else {
            throw AccountStoreError.activeCredentialMismatch
        }
        if let id = original.activeAccountID, !current.accounts.contains(where: { $0.id == id }) {
            throw AccountStoreError.activeProfileMissing
        }
        current.activeAccountID = original.activeAccountID
        current.accounts[target].lastUsedAt = originalTarget.lastUsedAt
        try saveRegistry(current)
    }

    private func saveRegistry(_ value: AccountRegistry) throws {
        try writeJSON(value, to: accountsURL)
        registry = value
    }

    private func saveUsageCache(_ value: UsageCache) throws {
        try writeJSON(value, to: usageCacheURL)
        usageCache = value
    }

    private func prepareDirectories() throws {
        try checkPath(baseURL)
        try checkPath(profilesURL)
        if let legacyBaseURL, fileManager.fileExists(atPath: legacyBaseURL.path) {
            try checkPath(legacyBaseURL)
            if fileManager.fileExists(atPath: baseURL.path) {
                // Never merge two stores: accounts and profile folders can have the same names.
                throw AccountStoreError.applicationSupportMigrationConflict
            }
            // Both paths are below Application Support, so this is a same-volume atomic rename.
            try fileManager.moveItem(at: legacyBaseURL, to: baseURL)
        }
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try restrictPermissions(baseURL, directory: true)
        try fileManager.createDirectory(at: profilesURL, withIntermediateDirectories: true)
        try restrictPermissions(profilesURL, directory: true)
        if !fileManager.fileExists(atPath: resetExpiryLogURL.path),
           fileManager.fileExists(atPath: legacyResetLogURL.path) {
            try checkPath(legacyResetLogURL)
            try? fileManager.moveItem(at: legacyResetLogURL, to: resetExpiryLogURL)
        }
    }

    private func readSavedBackup(id: UUID) throws -> Data? {
        if let backupVault { return try backupVault.read(accountID: id) }
        let file = profileHome(id: id).appending(path: "auth.json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        return try readChecked(file)
    }

    private func requireSavedBackup(id: UUID) throws -> Data {
        guard let data = try readSavedBackup(id: id) else { throw AccountStoreError.targetCredentialMissing }
        return data
    }

    private func writeSavedBackup(_ data: Data, id: UUID) throws {
        if let backupVault { try backupVault.write(data, accountID: id) }
        else { try secureAtomicWrite(data, to: profileHome(id: id).appending(path: "auth.json")) }
    }

    private func saveObservedActiveCredential(_ data: Data, id: UUID) throws {
        if backupVault is any ConsolidatingBackupCredentialVault,
           let profile = registry?.accounts.first(where: { $0.id == id }) {
            // Preserve the original newer-token check during the one-time migration.
            // Also retry any cleanup that failed after a previous shared commit.
            try migrateBackupIfNeeded(profile)
        }
        let existing = try readSavedBackup(id: id)
        guard existing != data else { return }
        if backupVault != nil, let existing,
           let existingTime = Self.refreshTime(of: existing), let activeTime = Self.refreshTime(of: data),
           existingTime > activeTime { return }
        try writeSavedBackup(data, id: id)
    }

    static func refreshTime(of credential: Data) -> Date? {
        struct Timestamp: Decodable { let last_refresh: String? }
        return (try? JSONDecoder().decode(Timestamp.self, from: credential))?.last_refresh
            .flatMap(ISO8601Timestamp.parse)
    }

    private func validateSavedIdentity(_ data: Data, profile: AccountProfile) throws {
        guard data.count <= ParsedCredential.maximumCredentialBytes,
              let identity = try CredentialIdentity.decode(data), identity.matches(profile) else {
            throw AccountStoreError.activeCredentialMismatch
        }
    }

    private func migrateBackupIfNeeded(_ profile: AccountProfile) throws {
        if let vault = backupVault as? any ConsolidatingBackupCredentialVault {
            try vault.consolidate(accountID: profile.id) { bytes in
                try validateMigratingIdentity(bytes, profile: profile)
            }
        }
        // Modern profiles have no plaintext backup. Do not read a protected
        // credential merely to find out that no file needs importing.
        let oldFile = profileHome(id: profile.id).appending(path: "auth.json")
        guard fileManager.fileExists(atPath: oldFile.path) else { return }
        guard let backupVault, try backupVault.read(accountID: profile.id) == nil else { return }
        let bytes = try readChecked(oldFile)
        try validateMigratingIdentity(bytes, profile: profile)
        try backupVault.write(bytes, accountID: profile.id)
        guard try backupVault.read(accountID: profile.id) == bytes else {
            throw AccountStoreError.targetCredentialMissing
        }
    }

    private func validateMigratingIdentity(_ bytes: Data, profile: AccountProfile) throws {
        if profile.accountID == nil {
            guard bytes.count <= ParsedCredential.maximumCredentialBytes,
                  let expected = profile.email, let actual = try CredentialIdentity.decode(bytes)?.email,
                  expected.caseInsensitiveCompare(actual) == .orderedSame else {
                throw AccountStoreError.activeCredentialMismatch
            }
        } else {
            try validateSavedIdentity(bytes, profile: profile)
        }
    }

    #if os(macOS)
    private func recoverInterruptedLogins(accounts: [AccountProfile]) throws {
        guard let backupVault else { return }
        let directories = try fileManager.contentsOfDirectory(at: profilesURL, includingPropertiesForKeys: nil)
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent), directory.lastPathComponent == id.uuidString else { continue }
            let marker = directory.appending(path: "pending-login")
            guard fileManager.fileExists(atPath: marker.path),
                  try fileManager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory,
                  try fileManager.attributesOfItem(atPath: marker.path)[.type] as? FileAttributeType == .typeRegular,
                  let pid = Int32(String(decoding: try readChecked(marker), as: UTF8.self)), pid > 0 else { continue }
            guard kill(pid, 0) == -1, errno == ESRCH else { continue }
            let auth = directory.appending(path: "auth.json")
            if accounts.contains(where: { $0.id == id }) {
                if fileManager.fileExists(atPath: auth.path) {
                    guard try backupVault.read(accountID: id) == readChecked(auth) else {
                        throw AccountStoreError.activeCredentialMismatch
                    }
                    try fileManager.removeItem(at: auth)
                }
                try fileManager.removeItem(at: marker)
            } else {
                try backupVault.remove(accountID: id)
                try removeProfileDirectory(directory)
            }
        }
    }
    #endif

    private func checkPath(_ path: URL) throws {
        #if os(Windows)
        let error = switcher_check_path(path.path)
        guard error == 0 else { throw windowsError(error) }
        #endif
    }

    private func readChecked(_ path: URL) throws -> Data {
        try checkPath(path)
        return try Data(contentsOf: path)
    }

    private func removeProfileDirectory(_ path: URL) throws {
        #if os(Windows)
        let error = switcher_remove_directory(path.path)
        guard error == 0 else { throw windowsError(error) }
        #else
        try fileManager.removeItem(at: path)
        #endif
    }

    private func secureAtomicWrite(_ bytes: Data, to destination: URL) throws {
        #if os(Windows)
        let error = bytes.withUnsafeBytes { buffer in
            switcher_atomic_write(destination.path, buffer.baseAddress, buffer.count)
        }
        guard error == 0 else { throw windowsError(error) }
        #else
        let temporary = destination
            .deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).switcher-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }

        do {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    guard count > 0 else { throw currentPOSIXError() }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
            guard Darwin.close(descriptor) == 0 else { throw currentPOSIXError() }
        } catch {
            _ = Darwin.close(descriptor)
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        if Darwin.rename(temporary.path, destination.path) != 0 {
            let error = currentPOSIXError()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        #endif
    }

    private func restrictPermissions(_ path: URL, directory: Bool) throws {
        #if os(Windows)
        let error = switcher_restrict_path(path.path, directory ? 1 : 0)
        guard error == 0 else { throw windowsError(error) }
        #else
        try fileManager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: path.path)
        #endif
    }

    #if os(Windows)
    private func windowsError(_ code: UInt32) -> NSError {
        NSError(domain: "CodexAccountSwitcher.Windows", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "Windows could not access private account storage (error \(code)).",
        ])
    }
    #else
    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    #endif

    private func writeJSON<T: Encodable>(_ value: T, to destination: URL) throws {
        let bytes = try Self.encoder.encode(value)
        try secureAtomicWrite(bytes, to: destination)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
