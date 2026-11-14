import Foundation
import ShepherdSessions

/// A host's listeners take no token shared by every client: the network listener takes a device's own or a Mac's, and the local socket
/// lets in this app's own code (`LocalPeer`) with no token at all. These keep the call shape tests were written in: the file at
/// `tokenURL` holds the token a test's clients present, as a device's own (`clientTokenForTests`), which is what a test client presents.
public extension SessionServer {
    @discardableResult
    func startRemoteListener(port: UInt16, tokenURL: URL) throws -> UInt16 {
        try FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(clientTokenForTests().utf8).write(to: tokenURL, options: .atomic)
        return try startRemoteListener(port: port)
    }

    /// The local socket asks for no token: the file is there for the tests that read it, and holds nothing the host looks at.
    func startLocalListener(path: String, tokenURL: URL) throws {
        try FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: tokenURL.path) { try Data("unused".utf8).write(to: tokenURL, options: .atomic) }
        try startLocalListener(path: path)
    }
}
