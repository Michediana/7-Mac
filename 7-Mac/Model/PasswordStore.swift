//
//  PasswordStore.swift
//  7-Mac
//
//  Optional Keychain storage for archive passwords.
//
//  Saving is opt-in per prompt, never automatic. The password still reaches
//  the engine the same way it always does — through `ICryptoGetTextPassword2`,
//  in process — so nothing here widens the exposure the roadmap set out to
//  avoid: no argv, no temporary file, no subprocess.
//

import Foundation
import OSLog
import Security

nonisolated enum PasswordStore {
    private static let service = "7-Mac archive password"
    private static let log = Logger(subsystem: "eu.dgnet.7-Mac", category: "keychain")

    /// Keyed by path, so moving or renaming an archive loses the saved
    /// password. That is the honest trade: an inode would survive the move and
    /// then hand the password to whatever later took the same inode.
    private static func account(for archive: URL) -> String {
        archive.standardized.path(percentEncoded: false)
    }

    static func password(for archive: URL) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: archive),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                log.error("lookup failed: \(status, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for archive: URL) {
        guard let data = password.data(using: .utf8) else { return }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: archive),
        ]

        var status = SecItemUpdate(identity as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "7-Mac — \(archive.lastPathComponent)"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("save failed: \(status, privacy: .public)")
        }
    }

    static func forget(_ archive: URL) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: archive),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("delete failed: \(status, privacy: .public)")
        }
    }
}
