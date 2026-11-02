import Foundation
import Security

/// Write-only password storage backed by the macOS Keychain.
///
/// There is deliberately no API that returns a password to the UI. The only
/// read path is `withPassword(slot:_:)`, which hands the secret to the sign-in
/// automation for the duration of one call and is never used by any view.
enum PasswordVault {
    private static let service = "com.ytsa.app.passwords"

    private static func baseQuery(slot: Int) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "slot-\(slot)",
        ]
    }

    static func save(_ password: String, slot: Int) -> Bool {
        delete(slot: slot)
        var query = baseQuery(slot: slot)
        query[kSecValueData as String] = Data(password.utf8)
        // Only readable while the Mac is unlocked, and never synced or migrated to another device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrLabel as String] = "YTSA account \(slot + 1)"
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(slot: Int) -> Bool {
        let status = SecItemDelete(baseQuery(slot: slot) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Checks existence without ever loading the secret bytes.
    static func exists(slot: Int) -> Bool {
        var query = baseQuery(slot: slot)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Sign-in automation only. The password is scoped to `body` and not retained.
    static func withPassword<T>(slot: Int, _ body: (String) async throws -> T) async rethrows -> T? {
        var query = baseQuery(slot: slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return try await body(password)
    }
}
