import Foundation
import Security

/// Where host tokens live. The app keeps them in the Keychain; checks and fixtures pass
/// `memory()` so they never touch it.
struct HostTokens {
    var read: (UUID) throws -> String?
    var save: (String, UUID) throws -> Void
    var remove: (UUID) throws -> Void
    /// The first client's single token (one host, one Keychain item), read once to migrate it.
    var readLegacy: () throws -> String?
    var removeLegacy: () throws -> Void

    /// A generic password per host, this device only, readable while unlocked, never synced.
    static let keychain = HostTokens(
        read: { try HostKeychain.read(account: HostKeychain.account($0)) },
        save: { try HostKeychain.save($0, account: HostKeychain.account($1)) },
        remove: { try HostKeychain.remove(account: HostKeychain.account($0)) },
        readLegacy: { try HostKeychain.read(account: HostKeychain.legacyAccount) },
        removeLegacy: { try HostKeychain.remove(account: HostKeychain.legacyAccount) }
    )

    /// Tokens held in memory for this process only.
    static func memory(_ initial: [UUID: String] = [:], legacy: String? = nil) -> HostTokens {
        final class Box: @unchecked Sendable {
            var tokens: [UUID: String]
            var legacy: String?
            init(_ tokens: [UUID: String], _ legacy: String?) { self.tokens = tokens; self.legacy = legacy }
        }
        let box = Box(initial, legacy)
        return HostTokens(
            read: { box.tokens[$0] },
            save: { box.tokens[$1] = $0 },
            remove: { box.tokens[$0] = nil },
            readLegacy: { box.legacy },
            removeLegacy: { box.legacy = nil }
        )
    }
}

enum HostKeychain {
    static let service = "com.bailycase.shepherd.ios.remote"
    /// The first client's one account.
    static let legacyAccount = "host-token"

    static func account(_ host: UUID) -> String { "host-" + host.uuidString.lowercased() }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw failure(status)
        }
        return token
    }

    static func save(_ token: String, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    static func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Could not reach the host token in the Keychain (\(status)).",
        ])
    }
}
