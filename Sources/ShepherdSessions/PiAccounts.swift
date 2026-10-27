import Foundation

/// One saved account for a provider, as Settings shows it: never its credential.
public struct PiAccount: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Rotation skips it until then (it hit the provider's limit).
    public var limitedUntil: Date?

    public init(id: String, name: String, limitedUntil: Date? = nil) {
        self.id = id
        self.name = name
        self.limitedUntil = limitedUntil
    }
}

/// A provider's saved accounts, in rotation order, and which one is in auth.json.
public struct PiAccountList: Equatable, Sendable {
    public var accounts: [PiAccount]
    public var active: String?
    /// Switch to the next account when the active one hits a limit.
    public var rotate: Bool

    public init(accounts: [PiAccount], active: String?, rotate: Bool) {
        self.accounts = accounts
        self.active = active
        self.rotate = rotate
    }

    public var activeAccount: PiAccount? { accounts.first { $0.id == active } }
}

/// Several accounts per provider (docs/pi-home.md › Accounts). pi reads one credential per
/// provider from the home's `auth.json`; the others wait in `shepherd-accounts.json` (0600) beside
/// it. Switching saves the active credential back first (refresh tokens rotate), then writes the
/// chosen one, under pi's lock; pi re-reads auth.json when it changes, so running agents use the
/// new account on their next request. A provider with no saved accounts works as it always did.
///
/// File: `{"<provider>": {"active", "rotate", "switchedAt", "accounts": [{"id", "name", "credential", "limitedUntil"}]}}`.
public struct PiAccounts: Sendable {
    public static let fileName = "shepherd-accounts.json"
    /// How long an account that hit a limit sits out of rotation.
    public static let cooldown: TimeInterval = 60 * 60
    /// A limit reported this soon after a switch is the old account's in-flight request, not the new one's.
    public static let grace: TimeInterval = 60

    let directory: URL
    var file: PiSettingsFile { PiSettingsFile(url: directory.appendingPathComponent(Self.fileName)) }
    var auth: PiSettingsFile { PiSettingsFile(url: directory.appendingPathComponent("auth.json")) }

    public init(home: PiHome) { directory = home.directory }
    init(directory: URL) { self.directory = directory }

    // MARK: Reading

    public func lists() -> [String: PiAccountList] {
        guard let data = try? Data(contentsOf: file.url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root.compactMapValues { value in
            guard let entry = value as? [String: Any] else { return nil }
            let accounts = (entry["accounts"] as? [[String: Any]] ?? []).compactMap { account -> PiAccount? in
                guard let id = account["id"] as? String else { return nil }
                return PiAccount(id: id, name: account["name"] as? String ?? "Account",
                                 limitedUntil: (account["limitedUntil"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
            return PiAccountList(accounts: accounts, active: entry["active"] as? String, rotate: entry["rotate"] as? Bool ?? false)
        }
    }

    // MARK: Changing

    /// Before another account signs in: the one in auth.json is saved (as "Account 1" the first
    /// time), so the new sign-in can replace it there.
    public func beginAdding(_ provider: String) throws {
        try edit(provider) { entry, auth in
            guard let current = auth[provider] else { return }
            if let index = Self.activeIndex(entry) {
                Self.setAccount(&entry, index, "credential", current)
            } else {
                let id = UUID().uuidString
                Self.append(&entry, ["id": id, "name": "Account 1", "credential": current])
                entry["active"] = id
            }
        }
    }

    /// A sign-in landed in auth.json: a new account when `adding`, else the active one's credential.
    @discardableResult
    public func landed(_ provider: String, adding: Bool) throws -> String? {
        var landedID: String?
        try edit(provider) { entry, auth in
            guard let current = auth[provider] else { return }
            if adding {
                let id = UUID().uuidString
                let count = (entry["accounts"] as? [Any])?.count ?? 0
                Self.append(&entry, ["id": id, "name": "Account \(count + 1)", "credential": current])
                entry["active"] = id
                landedID = id
            } else if let index = Self.activeIndex(entry) {
                Self.setAccount(&entry, index, "credential", current)
                Self.setAccount(&entry, index, "limitedUntil", nil)
                landedID = entry["active"] as? String
            }
        }
        return landedID
    }

    /// Makes `id` the account pi uses.
    public func activate(_ provider: String, _ id: String) throws {
        try edit(provider) { entry, auth in Self.switchTo(id, provider: provider, entry: &entry, auth: &auth) }
    }

    /// Removes a saved account. Removing the active one switches to the next, or signs out when it was the last.
    public func remove(_ provider: String, _ id: String) throws {
        try edit(provider) { entry, auth in
            var accounts = entry["accounts"] as? [[String: Any]] ?? []
            if entry["active"] as? String == id {
                if let next = accounts.first(where: { $0["id"] as? String != id }), let nextID = next["id"] as? String {
                    Self.switchTo(nextID, provider: provider, entry: &entry, auth: &auth)
                } else {
                    auth[provider] = nil
                    entry["active"] = nil
                }
            }
            accounts.removeAll { $0["id"] as? String == id }
            entry["accounts"] = accounts
        }
    }

    public func rename(_ provider: String, _ id: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try edit(provider) { entry, _ in
            guard let index = (entry["accounts"] as? [[String: Any]])?.firstIndex(where: { $0["id"] as? String == id }) else { return }
            Self.setAccount(&entry, index, "name", String(name.prefix(60)))
        }
    }

    public func setRotate(_ provider: String, _ on: Bool) throws {
        try edit(provider) { entry, _ in entry["rotate"] = on }
    }

    /// Signed out of the provider: its saved accounts go too.
    public func forget(_ provider: String) throws {
        try file.update { root in root[provider] = nil; return [] }
    }

    /// The active account hit a limit: when rotation is on, it sits out `cooldown` and the next
    /// account not sitting out takes over. Returns the names switched between, or nil when nothing
    /// switched (rotation off, a switch moments ago, or every account limited). Bounded: each
    /// account switches away at most once per cooldown, so a burst of limits stops once all have.
    public func rotate(_ provider: String, now: Date = Date()) throws -> (from: String, to: String)? {
        var result: (String, String)?
        try edit(provider) { entry, auth in
            guard entry["rotate"] as? Bool == true, let index = Self.activeIndex(entry) else { return }
            if let switched = entry["switchedAt"] as? Double, now.timeIntervalSince1970 - switched < Self.grace { return }
            let accounts = entry["accounts"] as? [[String: Any]] ?? []
            Self.setAccount(&entry, index, "limitedUntil", now.addingTimeInterval(Self.cooldown).timeIntervalSince1970)
            // The next in order after the active one, wrapping, that isn't sitting out.
            let order = accounts.indices.map { (index + 1 + $0) % accounts.count }.filter { $0 != index }
            guard let next = order.first(where: { (accounts[$0]["limitedUntil"] as? Double ?? 0) <= now.timeIntervalSince1970 }),
                  let nextID = accounts[next]["id"] as? String else { return }
            Self.switchTo(nextID, provider: provider, entry: &entry, auth: &auth)
            entry["switchedAt"] = now.timeIntervalSince1970
            result = (accounts[index]["name"] as? String ?? "Account", accounts[next]["name"] as? String ?? "Account")
        }
        return result.map { (from: $0.0, to: $0.1) }
    }

    // MARK: Plumbing

    private static let lock = NSLock()

    /// One provider's entry and auth.json, changed together: the accounts file's lock, then pi's.
    private func edit(_ provider: String, _ change: (inout [String: Any], inout [String: Any]) -> Void) throws {
        try Self.lock.withLock {
            _ = try file.update { root in
                var entry = root[provider] as? [String: Any] ?? [:]
                _ = try auth.update { auth in change(&entry, &auth); return [] }
                root[provider] = (entry["accounts"] as? [Any])?.isEmpty == false ? entry : nil
                return []
            }
        }
    }

    private static func activeIndex(_ entry: [String: Any]) -> Int? {
        guard let active = entry["active"] as? String else { return nil }
        return (entry["accounts"] as? [[String: Any]])?.firstIndex { $0["id"] as? String == active }
    }

    private static func append(_ entry: inout [String: Any], _ account: [String: Any]) {
        entry["accounts"] = (entry["accounts"] as? [[String: Any]] ?? []) + [account]
    }

    private static func setAccount(_ entry: inout [String: Any], _ index: Int, _ key: String, _ value: Any?) {
        var accounts = entry["accounts"] as? [[String: Any]] ?? []
        guard accounts.indices.contains(index) else { return }
        accounts[index][key] = value
        entry["accounts"] = accounts
    }

    /// Saves auth.json's credential into the active account, then puts `id`'s there.
    private static func switchTo(_ id: String, provider: String, entry: inout [String: Any], auth: inout [String: Any]) {
        let accounts = entry["accounts"] as? [[String: Any]] ?? []
        guard let target = accounts.firstIndex(where: { $0["id"] as? String == id }),
              let credential = accounts[target]["credential"] else { return }
        if let active = activeIndex(entry), active != target, let current = auth[provider] {
            setAccount(&entry, active, "credential", current)
        }
        auth[provider] = credential
        entry["active"] = id
    }
}
