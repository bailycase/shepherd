import Foundation
import ShepherdProtocol

extension ProjectResource {
    /// A resource as its file describes it: a skill's frontmatter `name` and `description`, a
    /// template's file name, `description` (else its first line) and `argument-hint`, a subagent's
    /// `name`, `description`, `tools` and `disabled`, an extension's file name and first comment.
    public init(kind: Kind, path: String, displayPath: String? = nil, text: String, global: Bool = false) {
        let profile = SubagentProfileText(text)
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        switch kind {
        case .skill:
            let front = SkillsText.frontmatter(text)
            self.init(kind: kind, name: front.name ?? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                      description: front.description ?? "", path: path, displayPath: displayPath, global: global)
        case .prompt:
            let first = profile.body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
            self.init(kind: kind, name: file, description: profile.scalar("description") ?? first, path: path, displayPath: displayPath,
                      global: global, detail: profile.scalar("argument-hint") ?? "")
        case .agent:
            self.init(kind: kind, name: profile.scalar("name") ?? file, description: profile.scalar("description") ?? "",
                      path: path, displayPath: displayPath, global: global, enabled: profile.bool("disabled") != true,
                      detail: (profile.list("tools") ?? []).joined(separator: " · "))
        case .extension:
            let comment = text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("//") || $0.hasPrefix("/*") || $0.hasPrefix("*") && $0 != "*/" }
            self.init(kind: kind, name: (path as NSString).lastPathComponent,
                      description: comment.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/* ")) } ?? "",
                      path: path, displayPath: displayPath, global: global)
        }
    }
}
