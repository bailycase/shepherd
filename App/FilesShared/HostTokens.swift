import Foundation
import Security

/// Where host tokens live. The app keeps them in the Keychain; checks and fixtures pass
/// `memory()` so they never touch it.
struct HostTokens {
    var read: (UUID) throws -> String?
    var save: (String, UUID) throws -> Void
    var remove: (UUID) throws -> Void
    /// This device's identity in a fleet (`MobileHosts.DeviceIdentity`, as JSON): one id and token for
    /// every Mac it is paired with, so one pairing works on all of them.
    var readDevice: () throws -> String? = { nil }
    var saveDevice: (String) throws -> Void = { _ in }

    /// A generic password per host, this device only, readable while unlocked, never synced.
    static let keychain = HostTokens(
        read: { try HostKeychain.read(account: HostKeychain.account($0)) },
        save: { try HostKeychain.save($0, account: HostKeychain.account($1)) },
        remove: { try HostKeychain.remove(account: HostKeychain.account($0)) },
        readDevice: { try HostKeychain.read(account: HostKeychain.deviceAccount) },
        // The device's identity stays the app's own: the Files extension needs only each Mac's token.
        saveDevice: { try HostKeychain.save($0, account: HostKeychain.deviceAccount, shared: false) }
    )

    /// Tokens held in memory for this process only.
    static func memory(_ initial: [UUID: String] = [:]) -> HostTokens {
        final class Box: @unchecked Sendable {
            var tokens: [UUID: String]
            var device: String?
            init(_ tokens: [UUID: String]) { self.tokens = tokens }
        }
        let box = Box(initial)
        return HostTokens(
            read: { box.tokens[$0] },
            save: { box.tokens[$1] = $0 },
            remove: { box.tokens[$0] = nil },
            readDevice: { box.device },
            saveDevice: { box.device = $0 }
        )
    }
}

/// The app writes host tokens into the app group's access group, so its Files extension (`FileProviderExtension`)
/// reaches the same Macs; reads search every group the process has.
enum HostKeychain {
    static let service = "com.bailycase.shepherd.ios.remote"
    /// The app group, which iOS also takes as a Keychain access group.
    static let accessGroup = "group.com.bailycase.shepherd.ios"
    /// This device's fleet identity (id and token).
    static let deviceAccount = "device-identity"

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

    static func save(_ token: String, account: String, shared: Bool = true) throws {
        var attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        if shared { attributes[kSecAttrAccessGroup as String] = accessGroup }
        var status = upsert(account, attributes)
        if status == errSecMissingEntitlement, shared {
            // A build signed without the app group (an unsigned simulator run) keeps the token to itself.
            attributes[kSecAttrAccessGroup as String] = nil
            status = upsert(account, attributes)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    private static func upsert(_ account: String, _ attributes: [String: Any]) -> OSStatus {
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
    }

    /// Moves a token saved before the extension existed into the shared group. Nothing happens to one already there
    /// or to a missing one.
    static func share(account: String) {
        _ = SecItemUpdate(query(account) as CFDictionary, [kSecAttrAccessGroup as String: accessGroup] as CFDictionary)
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
