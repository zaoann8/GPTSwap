import Foundation

// Shared account and usage types for both native platform clients.

public enum SwitcherVersion {
    public static let current = "0.2.1"
}

public struct AccountProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public let email: String?
    public var accountID: String?
    public let createdAt: Date
    public var lastUsedAt: Date?
    public var note: String?

    public init(
        id: UUID,
        displayName: String,
        email: String?,
        accountID: String?,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id; self.displayName = displayName; self.email = email
        self.accountID = accountID; self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
        self.note = note
    }

    private var normalizedNote: String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private var nonEmptyEmail: String? {
        email.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var preferredTitle: String {
        normalizedNote ?? nonEmptyEmail ?? displayName
    }

    public var labeledEmail: String? {
        normalizedNote == nil ? nil : nonEmptyEmail
    }

    public var confirmationTitle: String {
        normalizedNote ?? displayName
    }

    public var initials: String {
        let parts = displayName
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}

public struct AccountRegistry: Codable, Equatable, Sendable {
    public var activeAccountID: UUID?
    public var accounts: [AccountProfile]

    public init(activeAccountID: UUID?, accounts: [AccountProfile]) {
        self.activeAccountID = activeAccountID; self.accounts = accounts
    }

    public static let empty = AccountRegistry(activeAccountID: nil, accounts: [])
}

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese
    case italian

    public var id: String { rawValue }
}

public enum StatusBarUsageWindow: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case weekly

    public var id: String { rawValue }
}

public struct StatusBarQuotaReading: Equatable, Sendable {
    public let window: StatusBarUsageWindow
    public let percent: Int
    public let resetsAt: Date?

    public init(window: StatusBarUsageWindow, percent: Int, resetsAt: Date?) {
        self.window = window
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public enum PopoverAccountRows: Int, Codable, CaseIterable, Sendable {
    case three = 3
    case five = 5
    case eight = 8
}

public enum MenuBarRotationInterval: Int, Codable, CaseIterable, Sendable {
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case sixtySeconds = 60
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var language: AppLanguage
    public var showsMenuBarPercentage: Bool
    public var showsDockIcon: Bool
    public var rotatesMenuBarQuota: Bool
    public var menuBarRotationInterval: MenuBarRotationInterval
    public var showsFiveHourUsage: Bool
    public var statusBarUsageWindow: StatusBarUsageWindow
    public var autoResetEnabled: Bool
    public var popoverAccountRows: PopoverAccountRows
    public var lowUsageThreshold: Int?

    public static let lowUsageThresholdRange = 1...99

    public static let `default` = AppSettings(
        language: .system,
        showsMenuBarPercentage: true,
        showsFiveHourUsage: false,
        statusBarUsageWindow: .fiveHour
    )

    public init(
        language: AppLanguage,
        showsMenuBarPercentage: Bool = true,
        showsFiveHourUsage: Bool = false,
        statusBarUsageWindow: StatusBarUsageWindow = .fiveHour,
        autoResetEnabled: Bool = false,
        popoverAccountRows: PopoverAccountRows = .three,
        lowUsageThreshold: Int? = nil,
        showsDockIcon: Bool = true,
        rotatesMenuBarQuota: Bool = true,
        menuBarRotationInterval: MenuBarRotationInterval = .fifteenSeconds
    ) {
        self.language = language
        self.showsMenuBarPercentage = showsMenuBarPercentage
        self.showsFiveHourUsage = showsFiveHourUsage
        self.statusBarUsageWindow = statusBarUsageWindow
        self.autoResetEnabled = autoResetEnabled
        self.popoverAccountRows = popoverAccountRows
        self.lowUsageThreshold = lowUsageThreshold
        self.showsDockIcon = showsDockIcon
        self.rotatesMenuBarQuota = rotatesMenuBarQuota
        self.menuBarRotationInterval = menuBarRotationInterval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        showsMenuBarPercentage = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsMenuBarPercentage
        ) ?? true
        showsDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showsDockIcon) ?? true
        rotatesMenuBarQuota = try container.decodeIfPresent(Bool.self, forKey: .rotatesMenuBarQuota) ?? true
        menuBarRotationInterval = (try? container.decode(
            MenuBarRotationInterval.self, forKey: .menuBarRotationInterval
        )) ?? .fifteenSeconds
        showsFiveHourUsage = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsFiveHourUsage
        ) ?? false
        statusBarUsageWindow = try container.decodeIfPresent(
            StatusBarUsageWindow.self,
            forKey: .statusBarUsageWindow
        ) ?? .fiveHour
        autoResetEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .autoResetEnabled
        ) ?? false
        popoverAccountRows = try container.decodeIfPresent(
            PopoverAccountRows.self,
            forKey: .popoverAccountRows
        ) ?? .three
        lowUsageThreshold = try container.decodeIfPresent(Int.self, forKey: .lowUsageThreshold)
        if let lowUsageThreshold, !Self.lowUsageThresholdRange.contains(lowUsageThreshold) {
            throw DecodingError.dataCorruptedError(
                forKey: .lowUsageThreshold,
                in: container,
                debugDescription: "Low usage reminder threshold must be between 1 and 99."
            )
        }
    }
}

public struct WeeklyUsage: Codable, Equatable, Sendable {
    public let remainingPercent: Int?
    public let resetsAt: Date?
    public let fiveHourRemainingPercent: Int?
    public let fiveHourResetsAt: Date?
    public let resetCreditsRemaining: Int?
    public let resetCredits: [BankedResetCredit]?

    public init(
        remainingPercent: Int?,
        resetsAt: Date?,
        fiveHourRemainingPercent: Int? = nil,
        fiveHourResetsAt: Date? = nil,
        resetCreditsRemaining: Int? = nil,
        resetCredits: [BankedResetCredit]? = nil
    ) {
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.fiveHourRemainingPercent = fiveHourRemainingPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.resetCreditsRemaining = resetCreditsRemaining
        self.resetCredits = resetCredits
    }
}

public struct UsageCacheEntry: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let usage: WeeklyUsage
    public let fetchedAt: Date

    public init(profileID: UUID, usage: WeeklyUsage, fetchedAt: Date) {
        self.profileID = profileID; self.usage = usage; self.fetchedAt = fetchedAt
    }
}

public struct UsageCache: Codable, Equatable, Sendable {
    public var entries: [UsageCacheEntry]

    public init(entries: [UsageCacheEntry]) { self.entries = entries }

    public static let empty = UsageCache(entries: [])
}

public enum UsageViewState: Equatable, Sendable {
    case idle
    case loaded(WeeklyUsage)
    case stale(WeeklyUsage, String)
    case unavailable(String)

    public var displayedUsage: WeeklyUsage? {
        switch self {
        case let .loaded(usage), let .stale(usage, _):
            usage
        case .idle, .unavailable:
            nil
        }
    }

    public var refreshError: String? {
        guard case let .stale(_, message) = self else { return nil }
        return message
    }
}

public struct AccountIdentity: Equatable, Sendable {
    public let accountID: String?
    public let email: String?

    public init(accountID: String?, email: String?) { self.accountID = accountID; self.email = email }

    public var suggestedDisplayName: String {
        guard let email, let localPart = email.split(separator: "@").first else {
            return "Codex Account"
        }
        return String(localPart)
    }

    public func matches(_ profile: AccountProfile) -> Bool {
        if let expected = profile.accountID, let actual = accountID {
            guard expected == actual else { return false }
            if let expectedEmail = profile.email, let actualEmail = email {
                return expectedEmail.caseInsensitiveCompare(actualEmail) == .orderedSame
            }
            return true
        }
        // Known workspace IDs must never merge with an email-only profile.
        guard profile.accountID == nil, accountID == nil else { return false }
        if let expected = profile.email, let actual = email {
            return expected.caseInsensitiveCompare(actual) == .orderedSame
        }
        return false
    }
}

public enum SwitchStage: String, CaseIterable, Sendable {
    case closeDesktop
    case saveCurrentCredential
    case activateTargetCredential
    case verifyTargetIdentity
    case commitActiveAccountID
    case reopenDesktop
}

public struct OperationError: LocalizedError, Equatable, Sendable {
    public let stage: SwitchStage?
    public let titleKey: String
    public let messageKey: String?
    public let message: String
    public let underlyingDescription: String?

    public init(stage: SwitchStage?, titleKey: String, messageKey: String?, message: String, underlyingDescription: String?) {
        self.stage = stage; self.titleKey = titleKey; self.messageKey = messageKey
        self.message = message; self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? {
        let title = L10n.string(titleKey, language: .english)
        if let stage {
            return "\(title) (\(stage.rawValue)): \(message)"
        }
        return "\(title): \(message)"
    }

    public static func stage(_ stage: SwitchStage, _ error: any Error) -> OperationError {
        OperationError(
            stage: stage,
            titleKey: "switch_failed",
            messageKey: nil,
            message: error.localizedDescription,
            underlyingDescription: String(describing: error)
        )
    }
}

public enum AccountStoreError: LocalizedError, Equatable, Sendable {
    case profileNotFound
    case activeProfileMissing
    case activeCredentialMissing
    case activeCredentialMismatch
    case targetCredentialMissing
    case duplicateAccount
    case cannotRemoveActiveAccount
    case accountRemovalPending
    case accountOperationInProgress
    case invalidUsageThreshold
    case applicationSupportMigrationConflict

    public var errorDescription: String? {
        switch self {
        case .profileNotFound:
            "The account profile could not be found."
        case .activeProfileMissing:
            "No active account profile is configured."
        case .activeCredentialMissing:
            "The active Codex auth.json file is missing."
        case .activeCredentialMismatch:
            "The Codex login changed. No saved credential was overwritten. Refresh the account list before switching."
        case .targetCredentialMissing:
            "The selected account has no saved login credential. Sign in to this account again in Codex, then refresh the account list. Existing conversations are unchanged."
        case .duplicateAccount:
            "This account is already saved. Select the existing account instead."
        case .cannotRemoveActiveAccount:
            "The active account cannot be removed."
        case .accountRemovalPending:
            "The selected account has an unfinished removal. Retry removing it before switching to it."
        case .accountOperationInProgress:
            "Wait for the current account operation to finish."
        case .invalidUsageThreshold:
            "The low usage reminder requires a threshold from 1% to 99%."
        case .applicationSupportMigrationConflict:
            "Both the previous and gptswap data folders exist. No account data was changed. Resolve the duplicate folders before opening gptswap again."
        }
    }
}

public enum CodexClientError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case processLaunchFailed(String)
    case malformedResponse
    case remoteError(code: Int?, message: String)
    case connectionClosed
    case connectionClosedWithDetails(String)
    case timeout
    case identityUnavailable
    case weeklyUsageUnavailable
    case loginFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "The Codex executable could not be found."
        case let .processLaunchFailed(message):
            "Codex app-server failed to start: \(message)"
        case .malformedResponse:
            "Codex app-server returned malformed JSON."
        case let .remoteError(code, message):
            code.map { "Codex app-server error \($0): \(message)" } ?? "Codex app-server error: \(message)"
        case .connectionClosed:
            "Codex app-server closed the connection."
        case let .connectionClosedWithDetails(details):
            "Codex app-server closed the connection: \(details)"
        case .timeout:
            "Codex app-server did not respond before the timeout."
        case .identityUnavailable:
            "Codex did not return an account identity."
        case .weeklyUsageUnavailable:
            "No weekly Codex Usage window is available."
        case let .loginFailed(message):
            "Codex login failed: \(message)"
        }
    }
}
