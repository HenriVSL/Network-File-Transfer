//
//  Keychain.swift
//  Network File Transfer
//

import Foundation
import Security

/// Stores server credentials in the iOS Keychain, keyed by server ID.
enum Keychain {
    struct Secrets {
        var password = ""
        var privateKey = ""
        var passphrase = ""
    }

    private static let service = "Network-File-Transfer.credentials"

    private enum Field: String, CaseIterable {
        case password, privateKey, passphrase
    }

    static func secrets(for serverID: UUID) -> Secrets {
        Secrets(
            password: read(serverID, .password) ?? "",
            privateKey: read(serverID, .privateKey) ?? "",
            passphrase: read(serverID, .passphrase) ?? ""
        )
    }

    static func save(_ secrets: Secrets, for serverID: UUID) {
        write(secrets.password, serverID, .password)
        write(secrets.privateKey, serverID, .privateKey)
        write(secrets.passphrase, serverID, .passphrase)
    }

    static func deleteAll(for serverID: UUID) {
        for field in Field.allCases {
            SecItemDelete(query(serverID, field) as CFDictionary)
        }
    }

    private static func account(_ id: UUID, _ field: Field) -> String {
        "\(id.uuidString).\(field.rawValue)"
    }

    private static func query(_ id: UUID, _ field: Field) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, field),
        ]
    }

    private static func read(_ id: UUID, _ field: Field) -> String? {
        var q = query(id, field)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, _ id: UUID, _ field: Field) {
        let q = query(id, field)
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
