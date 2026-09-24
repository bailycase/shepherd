import ShepherdProtocol
import ShepherdSessions

/// A catalog the size of a real `pi --list-models` with every provider signed in: a few hundred
/// models across twenty providers, the gateways (OpenRouter, Vercel, Bedrock) carrying most of
/// them. Deterministic, so every run measures the same list.
enum ModelCatalogFixture {
    static let entries: [PiModelCatalog.Entry] = {
        var entries: [PiModelCatalog.Entry] = []
        var seen = Set<String>()
        func add(_ provider: String, _ model: String, _ context: String, reasoning: Bool = true) {
            let id = "\(provider)/\(model)"
            guard seen.insert(id).inserted else { return }
            entries.append(PiModelCatalog.Entry(id: id, context: context, reasoning: reasoning))
        }
        let anthropic = ["claude-3-5-haiku-20241022", "claude-3-5-sonnet-20241022", "claude-3-7-sonnet-20250219", "claude-haiku-4-5",
                         "claude-opus-4-0", "claude-opus-4-1", "claude-opus-4-5", "claude-opus-4-6", "claude-sonnet-4-0",
                         "claude-sonnet-4-5", "claude-sonnet-4-6", "claude-fable-5-1"]
        let openai = ["codex-mini-latest", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini", "gpt-5", "gpt-5-chat-latest",
                      "gpt-5-codex", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro", "gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-mini", "gpt-5.2",
                      "gpt-5.2-pro", "o1", "o1-pro", "o3", "o3-deep-research", "o3-mini", "o3-pro", "o4-mini", "o4-mini-deep-research"]
        let google = ["gemini-1.5-flash", "gemini-1.5-pro", "gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-2.5-flash",
                      "gemini-2.5-flash-lite", "gemini-2.5-flash-preview-09-2025", "gemini-2.5-pro", "gemini-3-flash-preview",
                      "gemini-3-pro-preview", "gemini-flash-latest", "gemini-flash-lite-latest", "gemini-live-2.5-flash"]
        for model in anthropic { add("anthropic", model, model.contains("4-6") ? "1M" : "200K") }
        for model in openai { add("openai", model, model.hasPrefix("gpt-4") ? "128K" : "400K", reasoning: !model.hasPrefix("gpt-4")) }
        for model in google { add("google", model, "1M") }
        for model in google { add("google-vertex", model, "1M") }
        for model in anthropic.suffix(8) { add("google-vertex-anthropic", model, "200K") }
        for model in openai.prefix(18) { add("azure-openai-responses", model, "400K") }
        for model in ["claude-haiku-4.5", "claude-opus-4.5", "claude-sonnet-4", "claude-sonnet-4.5", "gemini-2.5-pro", "gemini-3-pro-preview",
                      "gpt-4.1", "gpt-4o", "gpt-5", "gpt-5-mini", "gpt-5.1", "gpt-5.1-codex", "grok-code-fast-1", "o3", "o4-mini"] {
            add("github-copilot", model, "128K")
        }
        // The gateways: every vendor's families at every size they serve.
        let vendors: [(String, [String])] = [
            ("anthropic", anthropic.map { $0.replacingOccurrences(of: "-4-", with: "-4.") }),
            ("openai", openai),
            ("google", google),
            ("meta-llama", ["llama-3.1-8b-instruct", "llama-3.1-70b-instruct", "llama-3.1-405b-instruct", "llama-3.2-1b-instruct",
                            "llama-3.2-3b-instruct", "llama-3.2-11b-vision-instruct", "llama-3.2-90b-vision-instruct", "llama-3.3-70b-instruct",
                            "llama-4-maverick", "llama-4-scout", "llama-guard-4-12b"]),
            ("mistralai", ["codestral-2508", "devstral-medium", "devstral-small", "magistral-medium-2506", "magistral-small-2506",
                           "ministral-3b", "ministral-8b", "mistral-large-2411", "mistral-medium-3.1", "mistral-nemo", "mistral-small-3.2-24b-instruct",
                           "mixtral-8x22b-instruct", "pixtral-large-2411"]),
            ("deepseek", ["deepseek-chat", "deepseek-chat-v3.1", "deepseek-r1", "deepseek-r1-0528", "deepseek-r1-distill-llama-70b",
                          "deepseek-v3.1-terminus", "deepseek-v3.2-exp"]),
            ("qwen", ["qwen-2.5-72b-instruct", "qwen-2.5-coder-32b-instruct", "qwen-max", "qwen-plus", "qwen-turbo", "qwen3-14b", "qwen3-30b-a3b",
                      "qwen3-32b", "qwen3-235b-a22b", "qwen3-235b-a22b-thinking-2507", "qwen3-coder", "qwen3-coder-30b-a3b-instruct",
                      "qwen3-max", "qwen3-next-80b-a3b-instruct", "qwen3-vl-235b-a22b-instruct"]),
            ("x-ai", ["grok-3", "grok-3-mini", "grok-4", "grok-4-fast", "grok-4.1-fast", "grok-code-fast-1"]),
            ("moonshotai", ["kimi-k2", "kimi-k2-0905", "kimi-k2-thinking", "kimi-dev-72b"]),
            ("z-ai", ["glm-4.5", "glm-4.5-air", "glm-4.5v", "glm-4.6", "glm-4.6v", "glm-4.7"]),
            ("nousresearch", ["hermes-3-llama-3.1-70b", "hermes-3-llama-3.1-405b", "hermes-4-70b", "hermes-4-405b"]),
            ("cohere", ["command-a", "command-r-08-2024", "command-r-plus-08-2024", "command-r7b-12-2024"]),
            ("amazon", ["nova-lite-v1", "nova-micro-v1", "nova-premier-v1", "nova-pro-v1"]),
            ("microsoft", ["phi-4", "phi-4-multimodal-instruct", "phi-4-reasoning-plus", "wizardlm-2-8x22b"]),
            ("perplexity", ["sonar", "sonar-deep-research", "sonar-pro", "sonar-reasoning", "sonar-reasoning-pro"]),
        ]
        for (vendor, models) in vendors {
            for model in models { add("openrouter", "\(vendor)/\(model)", "128K") }
            for model in models.prefix(8) { add("openrouter", "\(vendor)/\(model):free", "32K", reasoning: false) }
        }
        for (vendor, models) in vendors { for model in models.prefix(10) { add("vercel-ai-gateway", "\(vendor)/\(model)", "128K") } }
        for (vendor, models) in vendors.prefix(8) {
            for model in models.prefix(9) { add("amazon-bedrock", "us.\(vendor).\(model)-v1:0", "200K") }
        }
        for model in ["llama-3.1-8b-instant", "llama-3.3-70b-versatile", "meta-llama/llama-4-maverick-17b-128e-instruct",
                      "meta-llama/llama-4-scout-17b-16e-instruct", "moonshotai/kimi-k2-instruct-0905", "openai/gpt-oss-120b",
                      "openai/gpt-oss-20b", "qwen/qwen3-32b", "deepseek-r1-distill-llama-70b", "gemma2-9b-it"] {
            add("groq", model, "128K", reasoning: false)
        }
        for model in ["gpt-oss-120b", "llama-3.3-70b", "llama3.1-8b", "qwen-3-235b-a22b-instruct-2507", "qwen-3-32b", "zai-glm-4.6"] {
            add("cerebras", model, "128K")
        }
        for model in ["grok-2-1212", "grok-2-vision-1212", "grok-3", "grok-3-fast", "grok-3-mini", "grok-3-mini-fast", "grok-4", "grok-4-0709",
                      "grok-4-fast-non-reasoning", "grok-4-fast-reasoning", "grok-4-1-fast", "grok-code-fast-1"] {
            add("xai", model, "256K")
        }
        for model in ["codestral-latest", "devstral-medium-latest", "devstral-small-latest", "magistral-medium-latest", "magistral-small-latest",
                      "ministral-3b-latest", "ministral-8b-latest", "mistral-large-latest", "mistral-medium-latest", "mistral-small-latest",
                      "open-mistral-nemo", "pixtral-large-latest"] {
            add("mistral", model, "128K")
        }
        for model in ["glm-4.5", "glm-4.5-air", "glm-4.5-flash", "glm-4.5v", "glm-4.6", "glm-4.6v", "glm-4.7"] { add("zai", model, "200K") }
        for model in ["deepseek-ai/DeepSeek-R1", "deepseek-ai/DeepSeek-V3.1", "moonshotai/Kimi-K2-Instruct", "Qwen/Qwen3-235B-A22B-Thinking-2507",
                      "Qwen/Qwen3-Coder-480B-A35B-Instruct", "openai/gpt-oss-120b", "zai-org/GLM-4.6"] {
            add("huggingface", model, "128K")
        }
        for model in ["big-pickle", "claude-opus-4-5", "claude-sonnet-4-5", "gemini-3-pro", "glm-4.6", "gpt-5", "gpt-5-codex", "gpt-5.1",
                      "grok-code", "kimi-k2", "qwen3-coder"] {
            add("opencode", model, "200K")
        }
        return entries
    }()

    /// Slash commands from a pi with many skills and prompt templates installed: as many as a
    /// snapshot carries (`NativeCommand.maxCount`).
    static let commands: [NativeCommand] = {
        var commands: [NativeCommand] = []
        for name in ["compact", "copy", "export", "fork", "hotkeys", "login", "logout", "model", "new", "reload", "resume", "session",
                     "settings", "share", "tree", "changelog"] {
            commands.append(NativeCommand(name: name, description: "Built-in \(name) command", source: "extension"))
        }
        let areas = ["api", "auth", "build", "cache", "ci", "config", "db", "deploy", "docs", "perf", "release", "review", "test", "ui"]
        let verbs = ["audit", "check", "draft", "explain", "fix", "plan", "refactor", "summarize"]
        for area in areas {
            for verb in verbs {
                commands.append(NativeCommand(name: "\(area)-\(verb)", description: "\(verb.capitalized) the \(area) layer following the team's checklist",
                                              source: area.count % 2 == 0 ? "prompt" : "skill"))
            }
        }
        return commands
    }()
}
