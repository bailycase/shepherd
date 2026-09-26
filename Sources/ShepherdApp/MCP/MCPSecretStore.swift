import Foundation
import Security

/// Where MCP secrets live: `secret/<server>/<NAME>` for a `${keychain:…}` value, and
/// `oauth/<server>` for a server's OAuth tokens (a JSON blob). Never in mcp.json.
protocol MCPSecretStore: AnyObject, Sendable {
    func value(for account: String) -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String)
    /// Every account that starts with `prefix`.
    func accounts(withPrefix prefix: String) -> [String]
}

extension MCPSecretStore {
    /// Removes a server's secrets and its OAuth tokens.
    func removeAll(forServer server: String) {
        for account in accounts(withPrefix: "secret/\(server)/") { remove(account) }
        remove(MCPSecretReference.oauthAccount(server: server))
    }
}

enum MCPSecrets {
    /// The app's store: the Keychain, under the running app's own service, so Dev, Shepherd and
    /// Shepherd Nightly never read each other's items. Anything but a Shepherd bundle (a test
    /// runner) gets a store in memory and never touches the Keychain.
    static func forApp(bundleID: String? = Bundle.main.bundleIdentifier) -> MCPSecretStore {
        guard let bundleID, bundleID.hasPrefix("com.bailycase.shepherd") else { return InMemorySecretStore() }
        return KeychainSecretStore(service: "\(bundleID).mcp")
    }
}

/// Generic passwords in the login keychain, readable after first unlock.
final class KeychainSecretStore: MCPSecretStore, @unchecked Sendable {
    let service: String

    init(service: String) {
        self.service = service
    }

    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func value(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Shepherd MCP \(account)"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    func accounts(withPrefix prefix: String) -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }.sorted()
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}

/// The only store tests use.
final class InMemorySecretStore: MCPSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]

    init(_ items: [String: String] = [:]) {
        self.items = items
    }

    func value(for account: String) -> String? {
        lock.withLock { items[account] }
    }

    func set(_ value: String, for account: String) throws {
        lock.withLock { items[account] = value }
    }

    func remove(_ account: String) {
        lock.withLock { items[account] = nil }
    }

    func accounts(withPrefix prefix: String) -> [String] {
        lock.withLock { items.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }
}
