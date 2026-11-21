import Foundation
import ShepherdSessions

/// Stands in for the OAuth bridge's Node process without contacting a provider. It waits
/// for the callback on stdin, so a refused completion must leave the bridge waiting.
public enum WaitingMCP {
    public static func setup(in directory: URL) throws -> PiSetup {
        let bridge = directory.appendingPathComponent("waiting-mcp")
        try Data("""
        #!/bin/sh
        IFS= read -r config || exit
        printf '%s\\n' '{"type":"event","event":{"type":"auth_url","url":"https://example.invalid/authorize"}}'
        IFS= read -r callback || exit
        printf '%s\\n' '{"type":"done","provider":"issues","credential":"oauth"}'

        """.utf8).write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        return PiSetup(engine: .init(command: ["/usr/bin/false"], packageDirectory: directory.path,
                                     version: nil, node: .executable(bridge.path)),
                       home: directory.appendingPathComponent("pi"), userHome: directory.path)
    }
}
