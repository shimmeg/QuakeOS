// KeychainStore.swift - Quake4Mac
//
// Small boundary for secrets. Non-secret preferences stay in UserDefaults; bearer
// refresh material and future credentials go through this helper.

import Foundation
import Security

protocol SecretStore {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String) throws
}

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

final class KeychainStore: SecretStore {
    static let shared = KeychainStore(service: "com.quake4mac.app")

    private let service: String

    init(service: String) {
        self.service = service
    }

    func string(forKey key: String) -> String? {
        var q = baseQuery(forKey: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setString(_ value: String?, forKey key: String) throws {
        guard let value else {
            let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainStoreError.unexpectedStatus(status)
            }
            return
        }

        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(forKey: key) as CFDictionary, update as CFDictionary)

        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw KeychainStoreError.unexpectedStatus(status)
        }

        var add = baseQuery(forKey: key)
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
