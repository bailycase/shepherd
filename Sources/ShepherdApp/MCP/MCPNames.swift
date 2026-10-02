import Foundation

/// Server names: what a tool prefix looks like, and a suggestion from a URL or a command.
enum MCPServerName {
    /// pi's rule for a server name: ASCII letters, digits, `-` and `_`.
    static func isValid(_ name: String) -> Bool {
        MCPPiConfig.isPiName(name)
    }

    /// What pi prefixes a server's tools with: `mcp__github`, and `mcp__my_server` for `my-server`.
    static func toolPrefix(_ name: String) -> String {
        "mcp__" + name.replacingOccurrences(of: "-", with: "_")
    }

    /// notion from mcp.notion.com, linear from mcp.linear.app, github from api.githubcopilot.com.
    static func suggested(for url: URL) -> String {
        let labels = (url.host ?? "").split(separator: ".").map(String.init)
        let generic: Set<String> = ["mcp", "api", "www", "app", "server", "com", "dev", "app", "io", "ai", "net", "org", "cloud"]
        let meaningful = labels.dropLast().filter { !generic.contains($0) }
        let pick = meaningful.last ?? labels.first ?? "server"
        return pick.hasSuffix("copilot") ? String(pick.dropLast("copilot".count)) : pick
    }

    /// playwright from `npx @playwright/mcp@latest`, grafana from `mcp-grafana`.
    static func suggested(forCommand words: [String]) -> String {
        let runners: Set<String> = ["npx", "uvx", "bunx", "pnpm", "dlx", "docker", "run", "node", "python", "python3", "-y", "--yes", "-i", "--rm"]
        let word = words.first { !runners.contains($0) && !$0.hasPrefix("-") } ?? words.first ?? "server"
        // A scoped package names its scope (@playwright/mcp → playwright); anything else its last part.
        var name = word.hasPrefix("@") ? String(word.dropFirst()).components(separatedBy: "/").first ?? word
            : (word as NSString).lastPathComponent
        name = name.components(separatedBy: "@").first ?? name
        for affix in ["mcp-server-", "mcp-", "server-"] where name.hasPrefix(affix) { name = String(name.dropFirst(affix.count)) }
        for affix in ["-mcp-server", "-mcp", "-server"] where name.hasSuffix(affix) { name = String(name.dropLast(affix.count)) }
        return name.isEmpty ? "server" : name
    }
}

/// A command line split into words the way a shell would, quotes kept together.
enum MCPCommandLine {
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var inWord = false
        for c in line {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" && quote != "'" { escaped = true; inWord = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; inWord = true; continue }
            if c == " " || c == "\t" {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(c)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }

    static func join(_ words: [String]) -> String {
        words.filter { !$0.isEmpty }.map { word in
            word.contains(where: { " \"'\\$".contains($0) }) ? "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" : word
        }.joined(separator: " ")
    }

    /// Where the login shell finds `program`, or nil.
    static func resolve(_ program: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", "command -v -- \"$0\"", program]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: process.terminationStatus == 0 && !path.isEmpty ? path : nil)
            }
        }
    }
}
