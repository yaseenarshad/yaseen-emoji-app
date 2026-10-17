import Foundation
import Security

/// The place of the KLIPY key (D2 of YAZ-2919). A test uses a fake one, so it never touches the real Keychain.
protocol KeyStore: Sendable {
    /// The key, or nil when there is none.
    func read() -> String?
    /// Keeps the key. An empty text (after `KlipyKey.clean`) removes it.
    func write(_ key: String) throws
}

/// The rules of the key text, the same for each store.
enum KlipyKey {
    /// A pasted key often has a space or a line break at an end. The key itself has none.
    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A Keychain call that failed, with the `OSStatus` of the Security framework.
struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// The real store: one generic password in this Mac's login Keychain (D2 of YAZ-2919).
/// The key never goes into a file, the git repo or `yaseen-os`. Only the app uses it, never a test.
struct KeychainKeyStore: KeyStore {
    static let service = "com.yaseenarshad.yaseenemoji"
    static let account = "klipy"

    /// The attributes that find the one item.
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeyStore.service,
            kSecAttrAccount as String: KeychainKeyStore.account,
        ]
    }

    func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        let clean = KlipyKey.clean(key)
        return clean.isEmpty ? nil : clean
    }

    func write(_ key: String) throws {
        let clean = KlipyKey.clean(key)
        guard !clean.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(clean.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query
        add[kSecValueData as String] = data
        // Only this Mac: the item does not go to iCloud Keychain, and it opens after the first unlock.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
