import Foundation
import Security

enum KeychainService {
    /// `afterFirstUnlock` keeps the item readable while the phone is locked (after the first unlock since
    /// boot) — for a secret a background task needs, e.g. the diagnostics token. The default stays
    /// "only while unlocked".
    static func write(_ key: String, value: String, afterFirstUnlock: Bool = false) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.nphil.stashy",
            kSecValueData: data,
            kSecAttrAccessible: afterFirstUnlock
                ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.nphil.stashy",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.nphil.stashy"
        ]
        SecItemDelete(query as CFDictionary)
    }
}
