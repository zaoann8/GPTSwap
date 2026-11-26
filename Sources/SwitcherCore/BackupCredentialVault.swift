import Foundation
#if os(macOS)
import Security
#endif

public protocol BackupCredentialVault: Sendable {
    func read(accountID: UUID) throws -> Data?
    func write(_ credential: Data, accountID: UUID) throws
    func remove(accountID: UUID) throws
    func addIfAbsent(_ credential: Data, accountID: UUID) throws -> Bool
}

public extension BackupCredentialVault {
    func addIfAbsent(_ credential: Data, accountID: UUID) throws -> Bool {
        guard try read(accountID: accountID) == nil else { return false }
        try write(credential, accountID: accountID)
        return true
    }
}

#if os(macOS)
public struct KeychainBackupCredentialVault: BackupCredentialVault {
    private let service: String

    public init(service: String = "local.gptswap.backup") {
        self.service = service
    }

    public func read(accountID: UUID) throws -> Data? {
        var query = item(accountID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data else { throw Failure.invalidData }
        return data
    }

    public func write(_ credential: Data, accountID: UUID) throws {
        var query = item(accountID)
        let update = [kSecValueData: credential] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            query[kSecValueData] = credential
            status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(item(accountID) as CFDictionary, update)
            }
        }
        try check(status)
    }

    public func addIfAbsent(_ credential: Data, accountID: UUID) throws -> Bool {
        var query = item(accountID)
        query[kSecValueData] = credential
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        try check(status)
        return true
    }

    public func remove(accountID: UUID) throws {
        let status = SecItemDelete(item(accountID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func item(_ accountID: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: accountID.uuidString]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private enum Failure: LocalizedError {
        case keychain(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .keychain(let status): "Unable to access saved credentials in the macOS Keychain (\(status))."
            case .invalidData: "The saved Keychain credential could not be read."
            }
        }
    }
}

/// The consolidated vault uses one fixed account name, never one item per UUID.
public struct SingleKeychainCredentialRecord: CredentialRecordStorage {
    public static let serviceName = "local.gptswap.backup"
    public static let accountName = "credential-vault-v1"
    public init() {}

    private var item: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.serviceName, kSecAttrAccount: Self.accountName]
    }

    public func read() throws -> Data? {
        var query = item
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.access(status) }
        guard let bytes = value as? Data else { throw Failure.invalidData }
        return bytes
    }

    public func write(_ data: Data) throws {
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = item
            query[kSecValueData] = data
            status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(item as CFDictionary, [kSecValueData: data] as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw Failure.access(status) }
    }

    private enum Failure: LocalizedError {
        case access(OSStatus), invalidData
        var errorDescription: String? {
            switch self {
            case .access(let status): "Unable to access the gptswap credential vault in the macOS Keychain (\(status))."
            case .invalidData: "The gptswap credential vault could not be read."
            }
        }
    }
}
#endif
