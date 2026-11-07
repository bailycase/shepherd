import Darwin
import Foundation
import Security

/// Who may use the local socket (`host.sock`): only a process of this user running this app's
/// own code (the app, as the host's client). pi and its agents run as the same user and can read
/// the token, but are signed as something else, so they are refused before `hello` is read.
enum LocalPeer {
    /// Whether the process at the other end of `fd` is this user's and satisfies this process's
    /// designated requirement (the same team and identifier; an ad-hoc build, its own cdhash).
    // ponytail: checked on the server queue at accept; local connections are rare. Move off the
    // queue if a slow code check ever shows up there.
    static func isTrusted(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0, let requirement = ownRequirement else { return false }
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &guest) == errSecSuccess,
              let guest else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    /// This process's designated requirement; nil for unsigned code, which trusts no one.
    static let ownRequirement: SecRequirement? = {
        var me: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()
}
