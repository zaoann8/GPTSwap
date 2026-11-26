import Foundation

// The same ordered handoff and bounded restoration run on both platforms.

public protocol DesktopControlling: Sendable {
    func closeDesktop() async throws
    func reopenDesktop() async throws
}

public protocol CodexIdentityReading: Sendable {
    func readIdentity(profileHome: URL) async throws -> AccountIdentity
}

public protocol SwitchServicing: Sendable {
    func switchAccount(to targetID: UUID) async throws
}

public struct SwitchService: SwitchServicing {
    public let desktop: any DesktopControlling
    public let store: any AccountStoring
    public let codex: any CodexIdentityReading

    public init(desktop: any DesktopControlling, store: any AccountStoring, codex: any CodexIdentityReading) {
        self.desktop = desktop; self.store = store; self.codex = codex
    }

    public func switchAccount(to targetID: UUID) async throws {
        let selection = try await prepareSwitch(to: targetID)
        do {
            try await desktop.closeDesktop()
        } catch {
            throw OperationError.stage(.closeDesktop, error)
        }

        try await installTarget(selection)

        do {
            try await desktop.reopenDesktop()
        } catch {
            throw await recover(.reopenDesktop, from: error) {
                // A failed launch can still have started the target desktop.
                try await desktop.closeDesktop()
                try await restoreCredential(for: selection.original)
                try await store.restoreActiveSelection(from: selection.registry, replacing: selection.target.id)
            }
        }
    }

    private struct Selection: Sendable {
        let target: AccountProfile
        let original: AccountProfile?
        let registry: AccountRegistry
    }

    private func prepareSwitch(to targetID: UUID) async throws -> Selection {
        let target: AccountProfile
        do {
            target = try await store.profile(id: targetID)
        } catch {
            throw OperationError.stage(.activateTargetCredential, error)
        }

        do {
            let registry = try await store.loadRegistry()
            if let activeID = registry.activeAccountID {
                guard let original = registry.accounts.first(where: { $0.id == activeID }) else {
                    throw AccountStoreError.activeProfileMissing
                }
                return Selection(target: target, original: original, registry: registry)
            }
            guard await !store.activeCredentialExists() else { throw AccountStoreError.activeProfileMissing }
            return Selection(target: target, original: nil, registry: registry)
        } catch {
            throw OperationError.stage(.saveCurrentCredential, error)
        }
    }

    private func installTarget(_ selection: Selection) async throws {
        var stage = SwitchStage.saveCurrentCredential
        do {
            try await saveOriginalCredential(selection.original)
            stage = .activateTargetCredential
            try await store.activateTargetCredential(id: selection.target.id)
            stage = .verifyTargetIdentity
            let identity = try await codex.readIdentity(profileHome: await store.activeCodexHome())
            guard identity.matches(selection.target) else { throw CodexClientError.identityUnavailable }
            stage = .commitActiveAccountID
            try await store.commitActiveAccountID(selection.target.id)
        } catch {
            let failedStage = stage
            throw await recover(failedStage, from: error) {
                // Activation and registry writes either commit atomically or throw before replacing the file.
                if failedStage == .verifyTargetIdentity || failedStage == .commitActiveAccountID {
                    try await restoreCredential(for: selection.original)
                }
            }
        }
    }

    private func saveOriginalCredential(_ original: AccountProfile?) async throws {
        if let original {
            let identity = try await codex.readIdentity(profileHome: await store.activeCodexHome())
            guard identity.matches(original) else { throw AccountStoreError.activeCredentialMismatch }
            try await store.saveCurrentCredential()
        } else if await store.activeCredentialExists() {
            throw AccountStoreError.activeCredentialMismatch
        }
    }

    private func restoreCredential(for original: AccountProfile?) async throws {
        guard let original else {
            if await store.activeCredentialExists() { try await store.clearActiveCredential() }
            guard await !store.activeCredentialExists() else { throw AccountStoreError.activeCredentialMismatch }
            return
        }
        try await store.restoreActiveCredential(id: original.id)
        let identity = try await codex.readIdentity(profileHome: await store.activeCodexHome())
        guard identity.matches(original) else { throw AccountStoreError.activeCredentialMismatch }
    }

    private func recover(
        _ stage: SwitchStage, from originalError: any Error, restore: @escaping @Sendable () async throws -> Void
    ) async -> OperationError {
        // Recovery must run even if the caller cancelled after closing Desktop.
        await Task {
            do {
                try await restore()
            } catch {
                return recoveryError(stage, original: originalError, recovery: error, reopening: false)
            }
            do {
                try await desktop.reopenDesktop()
            } catch {
                return recoveryError(stage, original: originalError, recovery: error, reopening: true)
            }
            if stage == .reopenDesktop {
                return OperationError(
                    stage: stage, titleKey: "switch_failed", messageKey: "switch_reopen_recovered",
                    message: L10n.string("switch_reopen_recovered", language: .english),
                    underlyingDescription: String(describing: originalError)
                )
            }
            return OperationError.stage(stage, originalError)
        }.value
    }

    private func recoveryError(
        _ stage: SwitchStage, original: any Error, recovery: any Error, reopening: Bool
    ) -> OperationError {
        let operation = reopening ? "Reopening Codex after recovery" : "Restoring the previous login"
        return OperationError(
            stage: stage,
            titleKey: "switch_failed",
            messageKey: nil,
            message: "\(original.localizedDescription) \(operation) also failed: \(recovery.localizedDescription)",
            underlyingDescription: "\(original); restoration: \(recovery)"
        )
    }
}
