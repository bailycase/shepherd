/// Bounded diagnostic labels only. Never retain source errors, tool names, paths or arguments.
public struct DiagnosticFailureDetails: Equatable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case auth, timeout, overloaded, server, rateLimit, network, contextTooLong, other
    }

    public enum ToolKind: String, CaseIterable, Sendable {
        case read, bash, write, edit, mcp, other

        public init(name: String) {
            switch name {
            case "read": self = .read
            case "bash": self = .bash
            case "write": self = .write
            case "edit": self = .edit
            default: self = name.hasPrefix("mcp__") ? .mcp : .other
            }
        }
    }

    public enum StartupStage: String, CaseIterable, Sendable {
        case preflight, launch, initialization, resume, unknown
    }

    public var category: Category?
    public var toolKind: ToolKind?
    public var startupKind: NativeStartProblem.Kind?
    public var startupStage: StartupStage?

    public init(category: Category? = nil, toolKind: ToolKind? = nil) {
        self.category = category
        self.toolKind = toolKind
    }

    public init(startupKind: NativeStartProblem.Kind) {
        self.startupKind = startupKind
        switch startupKind {
        case .homeUnsafe, .folderMissing: startupStage = .preflight
        case .engineMissing: startupStage = .launch
        case .notSignedIn, .extensionFailed: startupStage = .initialization
        case .resumedAsNew: startupStage = .resume
        case .exited: startupStage = .unknown
        }
    }

    public var attributes: [String: String] {
        var values: [String: String] = [:]
        values["failure.category"] = category?.rawValue
        values["tool.kind"] = toolKind?.rawValue
        values["startup.kind"] = startupKind?.rawValue
        values["startup.stage"] = startupStage?.rawValue
        return values
    }

    /// Revalidate at the telemetry boundary, including values supplied by ambient SDK scope.
    public static func sanitized(_ values: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        clean["failure.category"] = values["failure.category"].flatMap(Category.init(rawValue:))?.rawValue
        clean["tool.kind"] = values["tool.kind"].flatMap(ToolKind.init(rawValue:))?.rawValue
        clean["startup.kind"] = values["startup.kind"].flatMap(NativeStartProblem.Kind.init(rawValue:))?.rawValue
        clean["startup.stage"] = values["startup.stage"].flatMap(StartupStage.init(rawValue:))?.rawValue
        return clean
    }
}
