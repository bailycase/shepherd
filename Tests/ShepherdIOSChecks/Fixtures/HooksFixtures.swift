import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Settings › Hooks (MobileHooks, MobileHookEdit, MobileHookSources, iPadHooks): the board's hooks
// on Studio, its files, and the edit form with its test.
extension FixtureCatalog {
    static var hooks: [FixtureScreen] {
        [
            FixtureScreen(name: "settings-hooks", routes: [.settings(.hooks)], tab: .settings),
            FixtureScreen(name: "settings-hook-sources", routes: [.settings(.hooks), .settings(.hookSources)], tab: .settings),
            FixtureScreen(name: "settings-hook-edit", routes: [.settings(.hooks)], tab: .settings, prepare: { app in
                await FixtureData.editHook(app, json: false)
            }),
            FixtureScreen(name: "settings-hook-edit-json", routes: [.settings(.hooks)], tab: .settings, prepare: { app in
                await FixtureData.editHook(app, json: true)
            }),
            FixtureScreen(name: "settings-hooks-old", hosts: FixtureData.hostsWithoutHooks(), routes: [.settings(.hooks)], tab: .settings),
            FixtureScreen(name: "settings-pad-hooks", routes: [.settings(.root)], tab: .settings,
                          prepare: { app in app.navigator.settingsSelection.page = .hooks }),
            FixtureScreen(name: "settings-pad-hook-sources", routes: [.settings(.root)], tab: .settings, prepare: { app in
                app.navigator.settingsSelection.page = .hooks
                app.navigator.settingsSelection.hooksSources = true
            }),
        ]
    }
}

extension FixtureData {
    static let hooksHome = "/Users/sam"
    static let payments = "/Users/sam/code/payments"
    static let web = "/Users/sam/code/web"

    static func hookEntry(_ file: String, scope: HookScope, event: String, matcher: String, command: String, group: Int = 0, handler: Int = 0,
                          timeout: Double? = nil, status: String? = nil, on: Bool = true) -> HookEntry {
        let value = HookHandler.command(command, timeout: timeout, statusMessage: status)
        return HookEntry(slot: "\(file)#\(event)/\(group)/\(handler)", scope: scope, file: file, format: file.contains(".claude") ? .claude : file.contains(".codex") ? .codex : .shepherd,
                         event: event, matcher: matcher, groupIndex: group, handlerIndex: handler, handler: value,
                         hash: "fixture-\(event)-\(group)-\(handler)-\(file.count)", canonical: value.raw.canonical, editable: true, on: on)
    }

    /// The board's eight hooks: This Mac's in its three tools' files, payments' in two, and web's
    /// Codex file that doesn't parse.
    static func hooks() -> HookCatalogSnapshot {
        let h = hooksHome, p = payments
        let macShepherd = h + "/.shepherd/hooks.json", macClaude = h + "/.claude/settings.json", macCodex = h + "/.codex/hooks.json"
        let pShepherd = p + "/.shepherd/hooks.json", pClaude = p + "/.claude/settings.json"
        let space = HookScope.space(root: p), webSpace = HookScope.space(root: web)
        return HookCatalogSnapshot(
            sources: [
                HookSource(path: macShepherd, scope: .mac, format: .shepherd, isTOML: false, state: .loaded(count: 1)),
                HookSource(path: macClaude, scope: .mac, format: .claude, isTOML: false, state: .loaded(count: 2)),
                HookSource(path: macCodex, scope: .mac, format: .codex, isTOML: false, state: .loaded(count: 1)),
                HookSource(path: h + "/.codex/config.toml", scope: .mac, format: .codex, isTOML: true, state: .notFound),
                HookSource(path: pShepherd, scope: space, format: .shepherd, isTOML: false, state: .loaded(count: 3)),
                HookSource(path: pClaude, scope: space, format: .claude, isTOML: false, state: .loaded(count: 1)),
                HookSource(path: p + "/.codex/hooks.json", scope: space, format: .codex, isTOML: false, state: .notFound),
                HookSource(path: web + "/.shepherd/hooks.json", scope: webSpace, format: .shepherd, isTOML: false, state: .notFound),
                HookSource(path: web + "/.codex/hooks.json", scope: webSpace, format: .codex, isTOML: false,
                           state: .unreadable(line: 14, message: "expected “,”")),
            ],
            entries: [
                hookEntry(macClaude, scope: .mac, event: "SessionStart", matcher: "startup|resume", command: "python3 ~/.claude/hooks/session_notes.py"),
                hookEntry(macShepherd, scope: .mac, event: "PreToolUse", matcher: "Bash", command: "~/.shepherd/hooks/confirm-rm.sh"),
                hookEntry(pShepherd, scope: space, event: "PreToolUse", matcher: "Edit|Write", command: "\"$CLAUDE_PROJECT_DIR\"/.shepherd/hooks/no-env.sh",
                          timeout: 10, status: "Checking the path"),
                hookEntry(pClaude, scope: space, event: "PreToolUse", matcher: "Bash", command: "git-guard push --ask-on main", on: false),
                hookEntry(pShepherd, scope: space, event: "PostToolUse", matcher: "Edit|Write", command: "jq -r .tool_input.file_path | xargs npx prettier --write"),
                hookEntry(macClaude, scope: .mac, event: "Stop", matcher: "", command: "afplay /System/Library/Sounds/Glass.aiff", group: 0),
                hookEntry(macCodex, scope: .mac, event: "Stop", matcher: "", command: "terminal-notifier -message done"),
                hookEntry(pShepherd, scope: space, event: "Stop", matcher: "", command: "npm test --silent", group: 1),
            ],
            settings: HookSettings(), home: hooksHome)
    }

    /// The edit form's test: the board's no-env.sh refusing an edit to .env.
    static let hookTest = HookTestResult(exit: 2, stdout: "", stderr: "No edits to .env files.", milliseconds: 41,
                                         outcome: .blocked(reason: "No edits to .env files."))

    /// The usual hosts with Shepherds too old to serve hooks.
    static func hostsWithoutHooks() -> [FixtureHostData] {
        hosts().map { host in
            var host = host
            host.capabilities = host.defaultCapabilities.filter { $0 != RemoteProtocol.hooksCapability } + [RemoteProtocol.hooksCapability + ".old"]
            return host
        }
    }

    /// Opens payments' no-env.sh in the edit form and runs its test, as the board shows it.
    @MainActor static func editHook(_ app: MobileApp, json: Bool) async {
        let store = SettingsStore.of(app.hosts)
        guard let host = store.hosts.first(where: { $0.id == studio }) else { return }
        await store.hooks.refresh(host)
        guard let page = store.hooks.state(of: host).page, let entry = page.snapshot.entries.first(where: { $0.matcher == "Edit|Write" }) else { return }
        let editor = ClientHookEditor(editing: entry, in: page.snapshot)
        store.hookEditor = editor
        if json { editor.pane = .json } else { await editor.test(with: store.hooks, host: host) }
    }
}
