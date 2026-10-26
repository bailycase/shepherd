import Foundation
import Security

/// Keychain storage for push relay credentials, per host. Management credentials stay on
/// this device; only the registration ID and send token are shared with the paired Mac.
/// Separate from `HostKeychain` (different service) so forgetting push doesn't touch host auth.
enum PushKeychain {
    static let service = "com.bailycase.shepherd.ios.push"

    /// The stored relay credential for one host.
    struct Credential: Codable, Hashable, Sendable {
        var registrationID: String
        var sendToken: String
        var manageToken: String
        /// The device token hex at the time of registration, so we know when to PATCH.
        var deviceTokenHex: String
    }

    static func read(host: UUID) throws -> Credential? {
        let account = account(host)
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    static func save(_ credential: Credential, host: UUID) throws {
        let account = account(host)
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    static func remove(host: UUID) throws {
        let account = account(host)
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    // MARK: Private

    private static func account(_ host: UUID) -> String { "push-" + host.uuidString.lowercased() }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Could not access push credentials in the Keychain (\(status)).",
        ])
    }
}

/// In-memory replacement for tests and fixtures. Never touches the real Keychain.
final class PushKeychainMemory: @unchecked Sendable {
    private var store: [UUID: PushKeychain.Credential] = [:]
    private let lock = NSLock()

    func read(host: UUID) -> PushKeychain.Credential? { lock.withLock { store[host] } }
    func save(_ credential: PushKeychain.Credential, host: UUID) { lock.withLock { store[host] = credential } }
    func remove(host: UUID) { lock.withLock { store[host] = nil } }
}
