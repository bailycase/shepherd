import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Two repositories shaped like stock Spec Kit 1.2.3 projects with the pi integration (prompts, manifest,
/// init options, ignored feature pointer). The stub engine never expands templates: it proves the launch
/// named this worktree's `.pi/prompts`, that the named stock file exists, and plays deterministic writes.
/// Real template expansion through pi is the opt-in engine suite's job.
@MainActor
final class MissionSpecKitFixture {
    nonisolated static let model = MissionRuntimeFixture.model
    let app: AppHarness
    let repos: [URL]
    let spaces: [Space]
    let root: URL
    private(set) var controller: MissionController!
    var calls: URL { root.appendingPathComponent("calls.jsonl") }

    init() throws {
        root = try makeScratchDirectory("speckit-mission")
        var sources: [URL] = [], selected: [Space] = []
        for index in 0..<2 {
            let repo = try makeScratchRepo(files: Self.project())
            try Data("/project-script.json\n".utf8).write(to: repo.appendingPathComponent(".git/info/exclude"))
            sources.append(repo)
            selected.append(Space(name: "Repository \(index + 1)", path: repo.path))
        }
        repos = sources; spaces = selected
        app = try AppHarness(modelCatalog: { .init(models: [Self.model], defaultModel: Self.model) })
        try StubPi.installAsEngine()
        let config = root.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: ["root": root.path, "stub": StubPi.path]).write(to: config)
        let engine = root.appendingPathComponent("speckit-pi.py")
        try Data(Self.engine.utf8).write(to: engine)
        try Data("#!/bin/sh\nexec /usr/bin/env python3 \(shellQuoted(engine.path)) \(shellQuoted(config.path)) \"$@\"\n".utf8)
            .write(to: TestProcess.piEngine, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: TestProcess.piEngine.path)
    }

    static func project() -> [String: String] {
        var files: [String: String] = ["result.txt": "before\n", ".specify/.gitignore": "feature.json\n",
                                       ".specify/memory/constitution.md": "# Constitution\n",
                                       ".specify/scripts/bash/common.sh": "#!/usr/bin/env bash\n",
                                       ".specify/init-options.json": #"{"integration":"pi","script":"sh","feature_numbering":"sequential","speckit_version":"1.2.3"}"#,
                                       ".specify/integration.json": #"{"installed_integrations":["pi"],"default_integration":"pi"}"#]
        var manifest: [String: String] = [:]
        for command in SpecKitCommand.allCases {
            let text = "---\ndescription: stock \(command.rawValue)\n---\nSTOCK_\(command.rawValue.uppercased())\n$ARGUMENTS\n"
            files[command.promptPath] = text
            manifest[command.promptPath] = SpecKit.sha256(Data(text.utf8))
        }
        let data = try! JSONSerialization.data(withJSONObject: ["integration": "pi", "version": "1.2.3", "files": manifest], options: .sortedKeys)
        files[".specify/integrations/pi.manifest.json"] = String(decoding: data, as: UTF8.self)
        return files
    }

    func start() async throws {
        let vm = try await app.start()
        for space in spaces { try await app.server.addSpace(space) }
        try await eventuallyOnMain("Spec Kit repositories adopted") { vm.state.spaces.count == self.spaces.count }
        // Missions is an opt-in experiment (off by default); these journeys turn it on as a person would.
        vm.settings.missionsEnabled = true
        vm.openDestination(.missions)
        controller = vm.missions
        await controller.refreshModels()
    }

    func wait(_ id: MissionID, phase: MissionRun.Phase) async throws {
        try await eventuallyOnMain("Mission settles in \(phase.rawValue)", timeout: .seconds(60)) {
            self.app.server.state.missions.first { $0.id == id }?.run?.phase.active == false && self.controller.jobs[id] == nil
        }
        let mission = try controller.record(id)
        try #require(mission.run?.phase == phase, "\(mission.run?.notice ?? controller.error ?? "No diagnostic")")
    }

    func revision(_ id: MissionID) throws -> UInt64 { try controller.record(id).revision }

    func loggedCalls() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: calls, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func stop() { app.stop() }

    /// The protocol stub, with Spec Kit turns played in-thread so steers are taken while the turn works.
    static let engine = #"""
    import json, os, pathlib, subprocess, sys, time
    config = json.loads(pathlib.Path(sys.argv.pop(1)).read_text())
    root = pathlib.Path(config['root'])
    if '--list-models' in sys.argv:
        print('provider model context max-out thinking images\ntest model 200K 16K yes no')
        raise SystemExit(0)
    agent = os.environ['SHEPHERD_AGENT_ID']
    os.environ['STUB_PI_MODEL'] = json.dumps({'provider': 'test', 'id': 'model'})
    os.environ['STUB_PI_MODEL_APIS'] = json.dumps({'test/model': 'anthropic-messages'})
    os.environ['STUB_PI_SESSION_ID'] = agent
    os.environ['STUB_PI_LOG'] = str(root / (agent + '.rpc.jsonl'))
    templates = [sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == '--prompt-template']
    pathlib.Path('project-script.json').write_text('{"events":[]}')
    ns = {'__name__': '__main__', '__file__': config['stub']}
    original_stdin = sys.stdin

    def log(entry):
        with (root / 'calls.jsonl').open('a') as f:
            f.write(json.dumps(dict(entry, agent=agent, cwd=os.getcwd(), templates=templates, argv=sys.argv,
                                    denied=os.environ.get('SHEPHERD_CLI_DENIED'))) + '\n')

    def work(prompt):
        spec = pathlib.Path('specs/001-result/spec.md')
        if not prompt.startswith('/speckit.'):
            # An owner reply. Inside clarify it encodes the answer unless 'never-resolve'; CHANGE-SPEC edits the spec.
            if spec.exists() and '[NEEDS CLARIFICATION' in spec.read_text() and not (root / 'never-resolve').exists():
                spec.write_text(spec.read_text().replace('[NEEDS CLARIFICATION: which format?]', 'plain text (' + prompt + ')'))
                return 'Encoded the answer in spec.md.'
            if spec.exists() and '[NEEDS CLARIFICATION' in spec.read_text():
                return 'Q: Still unclear. Which format should result.txt use?'
            if 'CHANGE-PLAN' in prompt and spec.exists():
                with (spec.parent / 'plan.md').open('a') as f: f.write('- ' + prompt + '\n')
                return 'Updated plan.md.'
            if 'CHANGE-SPEC' in prompt and spec.exists():
                with spec.open('a') as f: f.write('- **FR-099**: ' + prompt + '\n')
                return 'Updated spec.md.'
            return 'Noted: ' + prompt
        command = prompt.split()[0][len('/speckit.'):]
        stock = [pathlib.Path(t) / ('speckit.' + command + '.md') for t in templates]
        if not any(p.is_file() for p in stock):
            return 'NO_STOCK_TEMPLATE'
        feature = pathlib.Path('specs/001-result')
        if command == 'specify':
            if (root / 'checkout-existing').exists():
                # The model switching to a branch that already existed: never the mission's own.
                subprocess.run(['git', 'checkout', '-q', 'existing'], check=True)
            if (root / 'git-feature').exists():
                # Stock git extension's mandatory before_specify hook: a new feature branch in this worktree.
                subprocess.run(['git', 'checkout', '-q', '-b', '001-result'], check=True)
            (feature / 'checklists').mkdir(parents=True, exist_ok=True)
            (feature / 'spec.md').write_text('# Feature Specification: Result\n### User Story 1 - Result (Priority: P1)\n- **FR-001**: result.txt MUST contain after\n'
                + ('- **FR-002**: Output format [NEEDS CLARIFICATION: which format?]\n' if (root / 'ask').exists() else ''))
            (feature / 'checklists/requirements.md').write_text('- [x] CHK001 Requirements are testable\n')
            pathlib.Path('.specify/feature.json').write_text(json.dumps({'feature_directory': str(feature)}))
        elif command == 'clarify':
            return 'Q1: Which format should result.txt use? (a) plain (b) json'
        elif command == 'plan' and (root / 'skip-plan-output').exists():
            (root / 'skip-plan-output').unlink()
            (feature / 'plan.md').unlink(missing_ok=True)
            return 'I could not write a plan.'
        elif command == 'plan':
            (feature / 'plan.md').write_text('# Plan\nWrite result.txt.\n')
            (feature / 'contracts').mkdir(exist_ok=True)
            (feature / 'contracts/cli.md').write_text('# CLI contract\n')
        elif command == 'tasks':
            (feature / 'tasks.md').write_text('# Tasks\n## Phase 1: Core\n- [ ] T001 Write after to result.txt\n')
        elif command == 'constitution':
            pathlib.Path('.specify/memory/constitution.md').write_text('# Result Constitution\n## Core Principles\n### I. Keep it simple\n')
            return 'Wrote the constitution from the repository.'
        elif command == 'analyze':
            if (root / 'critical-once').exists():
                (root / 'critical-once').unlink()
                return ('| ID | Category | Severity | Location(s) | Summary | Recommendation |\n|----|----|----|----|----|----|\n'
                        '| C1 | Coverage | CRITICAL | tasks.md | FR-001 has no test task | Add one |'
                        # As live: the findings, then a closing message about the optional git hook.
                        '\n<<SPLIT>>\nOptional Hook: git, /speckit.git.commit. Not executed; analysis remained read-only.')
            return 'No issues found. Critical Issues Count: 0'
        elif command == 'implement':
            if (root / 'implement-edits-spec').exists():
                with (feature / 'spec.md').open('a') as f: f.write('- **FR-001**: dropped, too hard\n')
            if (root / 'hold-after-contracts').exists():
                # Writes part of its output, then waits: the app pauses (or quits) mid-implement.
                (root / 'hold-after-contracts').unlink()
                with (feature / 'contracts/cli.md').open('a') as f: f.write('- partial\n')
                (root / 'implement-held').write_text('')
                deadline = time.time() + 30
                while not (root / 'release-implement').exists() and time.time() < deadline: time.sleep(0.05)
            if (root / 'hold-implement').exists():
                deadline = time.time() + 30
                while not (root / 'release-implement').exists() and time.time() < deadline: time.sleep(0.05)
                (root / 'hold-implement').unlink()
            pathlib.Path('result.txt').write_text('after\n')
            # As live implement runs do: a design artifact filled in alongside the code.
            with (feature / 'contracts/cli.md').open('a') as f: f.write('- result.txt holds after\n')
            tasks = feature / 'tasks.md'
            tasks.write_text(tasks.read_text().replace('- [ ]', '- [X]'))
            if (root / 'commit-implement').exists():
                # Stock git extension's after_implement commit hook, when the project runs it.
                subprocess.run(['git', 'add', '-A'], check=True)
                subprocess.run(['git', '-c', 'user.name=Spec Kit', '-c', 'user.email=speckit@example.com', 'commit', '-qm', '[Spec Kit] implement'], check=True)
        elif command == 'converge':
            if (root / 'append-once').exists():
                (root / 'append-once').unlink()
                with (feature / 'tasks.md').open('a') as f:
                    f.write('\n## Phase 2: Convergence\n- [ ] T002 Re-check result.txt per FR-001 (missing)\n')
                return 'Appended 1 task under Phase 2: Convergence.'
            return 'Converged: the implementation satisfies the spec, plan, and tasks.'
        return 'STOCK ' + command + ' done'

    def turn(prompt, unused):
        emit, now = ns['emit'], ns['now_ms']
        user = {'role': 'user', 'content': prompt, 'timestamp': now()}
        new = [user]
        emit({'type': 'agent_start'}); emit({'type': 'turn_start'})
        emit({'type': 'message_start', 'message': user}); emit({'type': 'message_end', 'message': user})
        log({'prompt': prompt})
        reply = work(prompt)
        # 'ignore-steer': the run ends without reading what is queued, as pi does when a steer misses its window.
        while not (root / 'ignore-steer').exists():
            taken = ns['take'](ns['steering'])
            if not taken: break
            message = ns['user_message'](*taken[0])
            emit({'type': 'message_start', 'message': message}); emit({'type': 'message_end', 'message': message})
            new.append(message)
            log({'steer': taken[0][0]})
            reply += ' (steered: ' + taken[0][0] + ')'
        *earlier, reply = reply.split('\n<<SPLIT>>\n')
        for part in earlier:
            message = {'role': 'assistant', 'content': [{'type': 'text', 'text': part}], 'stopReason': 'toolUse', 'timestamp': now()}
            emit({'type': 'message_start', 'message': dict(message, content=[])}); emit({'type': 'message_end', 'message': message})
            new.append(message)
        final = {'role': 'assistant', 'content': [{'type': 'text', 'text': reply}], 'stopReason': 'stop', 'timestamp': now()}
        emit({'type': 'message_start', 'message': dict(final, content=[])}); emit({'type': 'message_end', 'message': final})
        new.append(final)
        emit({'type': 'turn_end', 'message': final, 'toolResults': []})
        ns['MESSAGES'].extend(new)
        ns['STATE']['messageCount'] = len(ns['MESSAGES'])
        emit({'type': 'agent_end', 'messages': new[1:], 'willRetry': False})
        emit({'type': 'agent_settled'})

    class Input:
        buffer = None
        def __init__(self): self.buffer = self
        def __iter__(self):
            ns['script_turn'] = turn
            for t in templates:
                for p in sorted(pathlib.Path(t).glob('*.md')):
                    ns['COMMANDS'].append({'name': p.stem, 'description': 'stock', 'source': 'prompt', 'location': 'path', 'sourceInfo': {'path': str(p)}})
            for line in original_stdin.buffer:
                command = json.loads(line)
                if command.get('type') == 'prompt':
                    pathlib.Path('project-script.json').write_text(json.dumps({'prompts': {command['message']: []}}))
                yield line

    sys.stdin = Input()
    exec(compile(pathlib.Path(config['stub']).read_text(), config['stub'], 'exec'), ns)
    """#
}
