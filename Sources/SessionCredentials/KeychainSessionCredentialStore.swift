import Foundation
import Security

/// Persists one opaque refresh credential in this device's Keychain.
/// Each service/account pair is an independent slot.
public actor KeychainSessionCredentialStore: SessionCredentialStore {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func load() async throws -> RefreshCredential? {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainCredentialError.operationFailed(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError.invalidStoredCredential
        }
        return RefreshCredential(value: value)
    }

    public func store(_ credential: RefreshCredential) async throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(credential.value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialError.operationFailed(updateStatus)
        }
        var item = identity
        item.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
            if retryStatus == errSecSuccess { return }
            throw KeychainCredentialError.operationFailed(retryStatus)
        }
        throw KeychainCredentialError.operationFailed(addStatus)
    }

    public func clear() async throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.operationFailed(status)
        }
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Contains only a Keychain status code or a fixed description; never credential data.
public enum KeychainCredentialError: Error, Sendable, Equatable {
    case operationFailed(OSStatus)
    case invalidStoredCredential
}
