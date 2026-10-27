import Darwin
import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Use inside an exit test: installs fake executables only in that child's TestProcess sandbox.
/// The existing stub owns RPC startup, prompt acknowledgements, events, recovery and stats;
/// this adapter supplies only deterministic planner/worker/validator behavior.
@MainActor
final class MissionRuntimeFixture {
    nonisolated static let model = "test/model"
    let app: AppHarness
    let repos: [URL]
    let remotes: [URL]
    let spaces: [Space]
    let initialHeads: [String]
    let root: URL
    private(set) var controller: MissionController!
    var ghLog: URL { root.appendingPathComponent("gh.log") }
    var calls: URL { root.appendingPathComponent("calls.jsonl") }
    var commandPID: URL { root.appendingPathComponent("command.pid") }
    var childPID: URL { root.appendingPathComponent("child.pid") }

    init() throws {
        root = try makeScratchDirectory("mission")
        var sources: [URL] = [], destinations: [URL] = [], selected: [Space] = [], heads: [String] = []
        for index in 0..<2 {
            let repo = try makeScratchRepo(files: ["result.txt": "before\n"])
            let remote = root.appendingPathComponent("remote-\(index).git")
            try git(["init", "--bare", "-q", "-b", "main", remote.path], in: root)
            try git(["remote", "add", "origin", remote.path], in: repo)
            try git(["push", "-u", "origin", "main"], in: repo)
            try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repo)
            // The stub's script selector is fixture plumbing, never implementation content.
            try Data("/project-script.json\n".utf8).write(to: repo.appendingPathComponent(".git/info/exclude"))
            sources.append(repo); destinations.append(remote)
            selected.append(Space(name: "Repository \(index + 1)", path: repo.path))
            heads.append(try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        repos = sources; remotes = destinations; spaces = selected; initialHeads = heads
        app = try AppHarness(modelCatalog: { .init(models: [MissionRuntimeFixture.model], defaultModel: MissionRuntimeFixture.model) })
        try installExecutables()
    }

    func start() async throws {
        let vm = try await app.start()
        for space in spaces { try await app.server.addSpace(space) }
        try await eventuallyOnMain("Mission repositories adopted") { vm.state.spaces.count == self.spaces.count }
        // Missions is an opt-in experiment (off by default); these journeys turn it on as a person would.
        vm.settings.missionsEnabled = true
        vm.openDestination(.missions)
        controller = vm.missions
        // These scenarios cover the map runner; Spec Kit missions have their own fixture.
        controller.newMissionBackend = .legacyMap
        await controller.refreshModels()
        #expect(controller.availableModels == [Self.model])
    }

    func create(branches: [SpaceID: String]? = nil) async throws -> MissionID {
        let id = try await controller.create(goal: "Change result.txt to after in both repositories and verify it independently.",
                                             spaces: spaces.map(\.id), model: Self.model,
                                             branches: branches ?? Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, "refs/heads/main") }))
        try await wait(id, phase: .map)
        return id
    }

    func wait(_ id: MissionID, phase: MissionRun.Phase) async throws {
        try await eventuallyOnMain("Mission \(id) finishes \(phase.rawValue)", timeout: .seconds(60)) {
            let run = self.app.server.state.missions.first { $0.id == id }?.run
            return run?.phase.active == false && self.controller.jobs[id] == nil
        }
        let mission = try controller.record(id)
        try #require(mission.run?.phase == phase, "\(mission.run?.notice ?? controller.error ?? "No diagnostic")")
    }

    func launch(_ id: MissionID) async throws {
        try await controller.launch(id: id, revision: controller.record(id).revision)
    }

    func review(_ id: MissionID) async throws {
        try await launch(id)
        try await wait(id, phase: .review)
    }

    func setValidationFailure() throws {
        try Data().write(to: root.appendingPathComponent("fail-validation"))
    }

    func failFirstPRCreate() throws {
        try Data().write(to: root.appendingPathComponent("fail-first-pr-create"))
    }

    /// Owner edits the map through the same action as the editor, not runtime receipt injection.
    func holdFirstCheck(_ id: MissionID) async throws {
        let mission = try controller.record(id)
        var draft = mission.draft
        let index = try #require(draft.plan?.stations.firstIndex { $0.kind == .check })
        draft.plan?.stations[index].command = "python3 \(shellQuoted(root.appendingPathComponent("hold-check.py").path))"
        try await controller.saveDraft(id: id, revision: mission.revision, draft: draft)
    }

    func waitForCommand() async throws -> (Int32, Int32) {
        try await eventuallyOnMain("host check and its subprocess start", timeout: .seconds(60)) {
            FileManager.default.fileExists(atPath: self.commandPID.path) && FileManager.default.fileExists(atPath: self.childPID.path)
        }
        let parent = try #require(Int32(String(contentsOf: commandPID, encoding: .utf8)))
        let child = try #require(Int32(String(contentsOf: childPID, encoding: .utf8)))
        return (parent, child)
    }

    func expectSourcesUnchanged() throws {
        for (index, repo) in repos.enumerated() {
            #expect(try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines) == initialHeads[index])
            #expect(try git(["status", "--porcelain"], in: repo).isEmpty)
            #expect(try String(contentsOf: repo.appendingPathComponent("result.txt"), encoding: .utf8) == "before\n")
            #expect(try git(["rev-parse", "refs/heads/main"], in: remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines) == initialHeads[index])
        }
    }

    func expectUnpublished(_ id: MissionID) throws {
        let run = try #require(controller.record(id).run)
        #expect(run.publicationApproval == nil)
        #expect(!FileManager.default.fileExists(atPath: ghLog.path))
        for checkout in run.checkouts {
            let path = URL(fileURLWithPath: checkout.path)
            #expect(try git(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines) == checkout.head)
            #expect(checkout.prURL == nil && checkout.publishedHead == nil)
        }
        for remote in remotes {
            #expect(try git(["for-each-ref", "--format=%(refname)", "refs/heads/mission/"], in: remote).isEmpty)
        }
        try expectSourcesUnchanged()
    }

    func stop() { app.stop() }

    private func installExecutables() throws {
        try StubPi.installAsEngine()
        let config: [String: Any] = ["root": root.path, "stub": StubPi.path, "lanes": spaces.map { $0.id.rawValue }]
        let configURL = root.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        let engine = root.appendingPathComponent("mission-pi.py")
        try Data(Self.engine.utf8).write(to: engine)
        try executable("#!/bin/sh\nexec /usr/bin/env python3 \(shellQuoted(engine.path)) \(shellQuoted(configURL.path)) \"$@\"\n", at: TestProcess.piEngine)
        let gh = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(shellQuoted(ghLog.path))
        case "$1 $2" in
          'auth status') exit 0 ;;
          'pr list') printf '[]\\n' ;;
          'pr create')
            if [ -f \(shellQuoted(root.appendingPathComponent("fail-first-pr-create").path)) ]; then
              rm -- \(shellQuoted(root.appendingPathComponent("fail-first-pr-create").path))
              echo 'fixture: PR creation failed after push' >&2
              exit 1
            fi
            printf 'https://github.invalid/fixture/repo/pull/1\\n' ;;

          *) echo 'unexpected gh command' >&2; exit 90 ;;
        esac
        """
        try executable(gh + "\n", at: TestProcess.binDirectory.appendingPathComponent("gh"))
        let hold = """
        import os, pathlib, subprocess
        root = pathlib.Path(__file__).parent
        child = subprocess.Popen(['/bin/sleep', '60'])
        (root / 'child.pid').write_text(str(child.pid))
        (root / 'command.pid').write_text(str(os.getpid()))
        child.wait()
        (root / 'command-finished').write_text('unexpected completion')
        """
        try Data(hold.utf8).write(to: root.appendingPathComponent("hold-check.py"))
    }

    private func executable(_ text: String, at path: URL) throws {
        try Data(text.utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    // Reuse the protocol fixture unchanged. Only its scripted-turn callback is replaced;
    // the normal RPC dispatcher still acknowledges sends and streams/persists the turn.
    static let engine = #"""
    import json, os, pathlib, sys
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
    pathlib.Path('project-script.json').write_text('{"events":[]}')
    namespace = {'__name__': '__main__', '__file__': config['stub']}
    original_stdin = sys.stdin

    def mission_turn(prompt, unused):
        with (root / 'calls.jsonl').open('a') as log:
            log.write(json.dumps({'agent': agent, 'cwd': os.getcwd(), 'prompt': prompt}) + '\n')
        if prompt.startswith('SHEPHERD MISSION PLANNER'):
            stations, dependencies = [], []
            for i, lane in enumerate(config['lanes']):
                worker, check, validator = 'worker-' + str(i), 'check-' + str(i), 'validator-' + str(i)
                command = '''python3 -c 'from pathlib import Path; assert Path("result.txt").read_text() == "after\\n"; print("HOST_CHECK_OK")' '''.strip()
                for key, kind, goal in [(worker, 'worker', 'Write after followed by a newline to result.txt'), (check, 'check', 'Check actual file bytes'), (validator, 'validator', 'Independently inspect file and host check')]:
                    station = dict(id=key, kind=kind, lane=lane, title=key, goal=goal, doneWhen=['result.txt contains after'])
                    if kind == 'check': station['command'] = command
                    stations.append(station)
                dependencies += [dict(source=worker, target=check, kind='data', artifact='implementation'), dict(source=check, target=validator, kind='data', artifact='tested implementation')]
            reply = json.dumps(dict(summary='Two isolated edits, host checks and independent validators.', title='Update both repositories', requirements=['Both result.txt files contain after followed by a newline'], stations=stations, dependencies=dependencies))
            if (root / 'ask-clarification').exists():
                (root / 'ask-clarification').unlink()
                reply = json.dumps(dict(summary='Confirm the scope before planning.', question='Should both repositories use the same result format?'))
        elif prompt.startswith('SHEPHERD MISSION STATION: worker'):
            pathlib.Path('result.txt').write_text('after\n')
            reply = 'Changed only this lane result.txt; left it uncommitted.'
        elif prompt.startswith('SHEPHERD MISSION STATION: validator'):
            valid = pathlib.Path('result.txt').read_text() == 'after\n' and 'HOST_CHECK_OK' in prompt
            passed = valid and not (root / 'fail-validation').exists()
            reply = json.dumps(dict(passed=passed, evidence='Read actual result.txt; host command reports HOST_CHECK_OK.' if passed else 'Fixture rejects the acceptance condition; repair required.'))
        else:
            raise RuntimeError('Unexpected mission prompt: ' + prompt[:80])
        namespace['_original_script_turn'](prompt, [{'text': reply}])

    class Input:
        buffer = None
        def __init__(self): self.buffer = self
        def __iter__(self):
            namespace['_original_script_turn'] = namespace['script_turn']
            namespace['script_turn'] = mission_turn
            for line in original_stdin.buffer:
                command = json.loads(line)
                if command.get('type') == 'prompt':
                    pathlib.Path('project-script.json').write_text(json.dumps({'prompts': {command['message']: []}}))
                yield line

    sys.stdin = Input()
    exec(compile(pathlib.Path(config['stub']).read_text(), config['stub'], 'exec'), namespace)
    """#
}
