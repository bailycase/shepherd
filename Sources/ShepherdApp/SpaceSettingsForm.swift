import Foundation

/// The space Settings form (ProjectSettings board) over a space's pi `settings.json`. The file stays
/// the truth: the form reads values out of the editor's draft and writes them back into it, so
/// keys the form doesn't show are kept, and saving, discarding and conflicts follow the file's rules.
/// An unset key follows `inherited`: the host's global settings over pi's documented defaults.
enum SpaceSettingsForm {
    struct Option: Hashable { var value: String; var label: String }
    enum Control: Equatable { case dropdown([Option]), segments([Option]), field, number, stepper }

    struct Row: Equatable, Identifiable {
        var key: String
        var label: String
        var description: String
        var control: Control
        /// What the control shows: "" for an unset dropdown or segment ("Follow global"), else the space's value.
        var value: String
        /// The space's value, or the inherited one when unset (the stepper's number).
        var effective: Int
        /// "Space override · Global: High", "Inherited from Global · Global: Medium".
        var source: String
        var placeholder: String
        var error: String?
        var overridden: Bool
        var id: String { key }
    }

    struct Group: Equatable, Identifiable {
        var title: String
        var note: String
        var rows: [Row]
        var tools = false
        var id: String { title }
    }

    static let tools = ["read", "bash", "edit", "write", "grep", "find", "ls"]
    static let thinkingLevels = [("off", "Off"), ("minimal", "Minimal"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max")]
    /// pi's own defaults (docs/settings.md), for a key global settings leave unset.
    static let piDefaults: [String: Any] = [
        "defaultThinkingLevel": "medium", "defaultTools": ["read", "bash", "edit", "write"],
        "compaction": ["enabled": true, "reserveTokens": 16384, "keepRecentTokens": 20000],
        "retry": ["enabled": true, "maxRetries": 3],
    ]
    static let numberKeys: Set<String> = ["compaction.reserveTokens", "compaction.keepRecentTokens", "retry.maxRetries"]

    // MARK: JSON

    /// The draft as an object: an empty or missing file is `[:]`, anything else that isn't an object is nil.
    static func parse(_ text: String) -> [String: Any]? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func serialize(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func value(_ key: String, in object: [String: Any]) -> Any? {
        var current: Any? = object
        for part in key.split(separator: ".") { current = (current as? [String: Any])?[String(part)] }
        return current
    }

    /// `object` with `key` set, or removed when `value` is nil; a nested object left empty goes too.
    static func setting(_ key: String, to value: Any?, in object: [String: Any]) -> [String: Any] {
        let parts = key.split(separator: ".").map(String.init)
        func set(_ object: [String: Any], _ index: Int) -> [String: Any] {
            var object = object
            let part = parts[index]
            if index == parts.count - 1 {
                object[part] = value
            } else {
                let child = set(object[part] as? [String: Any] ?? [:], index + 1)
                object[part] = child.isEmpty ? nil : child
            }
            return object
        }
        return set(object, 0)
    }

    /// Global settings over pi's defaults, nested objects merged key by key.
    static func merged(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        base.merging(over) { old, new in
            if let old = old as? [String: Any], let new = new as? [String: Any] { return merged(old, new) }
            return new
        }
    }

    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBool(number), number.doubleValue == number.doubleValue.rounded(),
              number.doubleValue >= 0, number.doubleValue <= Double(Int.max / 2) else { return nil }
        return number.intValue
    }

    /// pi's tool selection: plain names replace `base`, a list of only `+name` and `-name` edits it.
    static func resolvedTools(_ value: Any?, base: [String]) -> [String] {
        guard let list = value as? [String] else { return base }
        guard !list.isEmpty, list.allSatisfy({ $0.hasPrefix("+") || $0.hasPrefix("-") }) else { return list }
        var tools = base
        for entry in list {
            let name = String(entry.dropFirst())
            if entry.hasPrefix("+") { if !tools.contains(name) { tools.append(name) } } else { tools.removeAll { $0 == name } }
        }
        return tools
    }

    static func error(_ key: String, in object: [String: Any]) -> String? {
        guard let raw = value(key, in: object) else { return nil }
        if numberKeys.contains(key) { return integer(raw) == nil ? "Enter a whole number of 0 or more." : nil }
        if key == "shellPath" {
            guard let path = raw as? String, path.hasPrefix("/") || path.hasPrefix("~/"), !hasControl(path) else { return "Use an absolute shell path, such as /bin/zsh." }
        }
        if key == "shellCommandPrefix" {
            guard let prefix = raw as? String, !hasControl(prefix) else { return "Use one line without control characters." }
        }
        return nil
    }

    static func invalid(_ object: [String: Any]) -> Bool {
        (numberKeys.union(["shellPath", "shellCommandPrefix"])).contains { error($0, in: object) != nil }
    }

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    // MARK: Rows

    static func model(_ object: [String: Any]) -> String? {
        guard let provider = object["defaultProvider"] as? String, !provider.isEmpty,
              let model = object["defaultModel"] as? String, !model.isEmpty else { return nil }
        return provider + "/" + model
    }

    static func display(_ value: Any?, options: [Option]? = nil) -> String {
        if isBool(value) { return (value as? Bool) == true ? "On" : "Off" }
        if let options, let string = value as? String, let match = options.first(where: { $0.value == string }) { return match.label }
        if let list = value as? [String] { return list.isEmpty ? "none" : list.joined(separator: ", ") }
        if let number = value as? NSNumber { return number.stringValue }
        if let string = value as? String, !string.isEmpty { return string }
        return "none"
    }

    /// The form's groups for the space's settings `object`, unset values following `inherited`
    /// (named `inheritedName`, "Global"). `models` are `provider/model` ids to offer.
    static func groups(_ object: [String: Any], inherited: [String: Any], inheritedName: String = "Global", models: [String]) -> [Group] {
        let follow = "Follow " + inheritedName.lowercased()
        func row(_ key: String, _ label: String, _ description: String, _ control: Control) -> Row {
            let raw = value(key, in: object), base = value(key, in: inherited)
            var options: [Option]?
            if case .dropdown(let list) = control { options = list } else if case .segments(let list) = control { options = list }
            let shown: String
            if raw == nil { shown = "" } else if isBool(raw) { shown = (raw as? Bool) == true ? "true" : "false" } else if let number = raw as? NSNumber { shown = number.stringValue } else { shown = raw as? String ?? "" }
            return Row(key: key, label: label, description: description, control: control, value: shown,
                       effective: integer(raw) ?? integer(base) ?? 0,
                       source: (raw == nil ? "Inherited from \(inheritedName)" : "Space override") + " · \(inheritedName): \(display(base, options: options))",
                       placeholder: "\(inheritedName): \(display(base))", error: error(key, in: object), overridden: raw != nil)
        }
        let baseModel = model(inherited)
        var modelIDs = models
        if let current = model(object), !modelIDs.contains(current) { modelIDs.append(current) }
        var modelRow = row("defaultModel", "Startup model", "The model new threads in this space start with.",
                           .dropdown([Option(value: "", label: "\(follow) · \(baseModel ?? "pi's choice")")] + modelIDs.map { Option(value: $0, label: $0) }))
        modelRow.value = model(object) ?? ""
        modelRow.overridden = object["defaultModel"] != nil || object["defaultProvider"] != nil
        modelRow.source = (modelRow.overridden ? "Space override" : "Inherited from \(inheritedName)") + " · \(inheritedName): \(baseModel ?? "pi's choice")"
        let baseLevel = thinkingLevels.first { $0.0 == inherited["defaultThinkingLevel"] as? String }?.1 ?? display(inherited["defaultThinkingLevel"])
        let thinking = row("defaultThinkingLevel", "Thinking level", "Default reasoning effort for new sessions.",
                           .dropdown([Option(value: "", label: "\(follow) · \(baseLevel)")] + thinkingLevels.map { Option(value: $0.0, label: $0.1) }))
        var toolsRow = row("defaultTools", "Built-in tools", "Choose whether this space follows inherited tool selection.",
                           .segments([Option(value: "", label: follow.capitalizedFirst), Option(value: "project", label: "Space selection")]))
        toolsRow.value = toolsRow.overridden ? "project" : ""
        let tri = [Option(value: "", label: follow.capitalizedFirst), Option(value: "true", label: "On"), Option(value: "false", label: "Off")]
        return [
            Group(title: "Model and thinking", note: "Choose how new agents start in this space.", rows: [modelRow, thinking]),
            Group(title: "Built-in tools", note: "Pi’s built-in file and shell tools, selected per space.", rows: [toolsRow], tools: true),
            Group(title: "Compaction", note: "Keep room in the context window without losing recent work.", rows: [
                row("compaction.enabled", "Automatic compaction", "Compact the context when it approaches the limit.", .segments(tri)),
                row("compaction.reserveTokens", "Reserved tokens", "Space to leave available for the next response.", .number),
                row("compaction.keepRecentTokens", "Recent tokens to keep", "Recent context to retain during compaction.", .number),
            ]),
            Group(title: "Retry", note: "Retry transient provider errors.", rows: [
                row("retry.enabled", "Automatic retry", "Retry requests after a temporary failure.", .segments(tri)),
                row("retry.maxRetries", "Maximum retries", "Number of retries before reporting an error.", .stepper),
            ]),
            Group(title: "Shell", note: "Shell configuration only. No commands run in this form.", rows: [
                row("shellPath", "Shell path", "Use an absolute executable path. Leave blank to inherit.", .field),
                row("shellCommandPrefix", "Command prefix", "One-line prefix for shell commands. Leave blank to inherit.", .field),
            ]),
        ]
    }

    /// What a control's change writes: "" removes the key so it inherits again.
    static func applying(_ key: String, _ input: String, control: Control, to object: [String: Any], inherited: [String: Any]) -> [String: Any] {
        if key == "defaultModel" {
            var next = setting("defaultProvider", to: nil, in: setting("defaultModel", to: nil, in: object))
            if let slash = input.firstIndex(of: "/"), slash != input.startIndex {
                next["defaultProvider"] = String(input[..<slash]); next["defaultModel"] = String(input[input.index(after: slash)...])
            }
            return next
        }
        if key == "defaultTools" {
            let base = resolvedTools(inherited["defaultTools"], base: [])
            return setting(key, to: input.isEmpty ? nil : base, in: object)
        }
        guard !input.isEmpty else { return setting(key, to: nil, in: object) }
        switch control {
        case .segments: return setting(key, to: input == "true", in: object)
        case .number, .stepper: return setting(key, to: Int(input).map { $0 as Any } ?? input, in: object)
        default: return setting(key, to: input, in: object)
        }
    }

    /// The tools checked: the space's selection, or the inherited one while it follows.
    static func selectedTools(_ object: [String: Any], inherited: [String: Any]) -> [String] {
        let base = resolvedTools(inherited["defaultTools"], base: [])
        return object["defaultTools"] == nil ? base : resolvedTools(object["defaultTools"], base: base)
    }

    /// Turning a tool on or off writes a plain list, keeping any other tool it names (codemode, powershell).
    static func toggling(_ tool: String, on: Bool, in object: [String: Any], inherited: [String: Any]) -> [String: Any] {
        var tools = selectedTools(object, inherited: inherited)
        if on { if !tools.contains(tool) { tools.append(tool) } } else { tools.removeAll { $0 == tool } }
        return setting("defaultTools", to: tools, in: object)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
