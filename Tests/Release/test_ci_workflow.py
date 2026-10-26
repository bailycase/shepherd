"""Structure rules for .github/workflows/ci.yml and the swift-build action.

The workflow is read as text (the repository's tests are stdlib only). Run:
python3 -m unittest discover -s Tests/Release -v
"""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ci_plan  # noqa: E402


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


WORKFLOW = read(".github", "workflows", "ci.yml")
ACTION = read(".github", "actions", "swift-build", "action.yml")


def jobs(text):
    """Job name to its text, for the jobs under the top-level `jobs:` key."""
    out, name, lines = {}, None, []
    for line in text.split("\njobs:\n", 1)[1].splitlines():
        m = re.match(r"^  ([a-z][a-z-]*):\s*$", line)
        if m or re.match(r"^  \S", line):
            if name:
                out[name] = "\n".join(lines) + "\n"
            name, lines = (m.group(1) if m else None), []
        elif name:
            lines.append(line)
    if name:
        out[name] = "\n".join(lines) + "\n"
    return out


def needs(job):
    m = re.search(r"^    needs: (?:\[([^\]]*)\]|(\S+))\s*$", job, re.M)
    if not m:
        return []
    return [n.strip() for n in (m.group(1) or m.group(2)).split(",")]


def run_script(job):
    """The script of the first `run: |` step of a job."""
    m = re.search(r"^( +)(?:- )?run: \|\n((?:\1  .*\n?)+)", job, re.M)
    assert m, "no run: | step"
    return "\n".join(line[len(m.group(1)) + 2:] for line in m.group(2).splitlines())


JOBS = jobs(WORKFLOW)


class WorkflowShapeTests(unittest.TestCase):
    def test_pull_request_ci_targets_only_master(self):
        trigger = re.search(r"(?ms)^  pull_request:\n(.*?)(?=^  [a-z_]+:)", WORKFLOW)
        self.assertIsNotNone(trigger)
        self.assertRegex(trigger.group(1), r"(?m)^    branches: \[master\]$")

    def test_no_path_filter_can_stop_ci_from_reporting(self):
        # A workflow filtered out by paths never reports `CI`, so a pull request would wait for it for ever.
        self.assertNotRegex(WORKFLOW, r"(?m)^\s+paths(-ignore)?:")

    def test_ci_is_the_one_gate_and_it_waits_for_every_job_that_can_fail_a_run(self):
        gate = JOBS["ci"]
        self.assertIn("'UI diagnostics' || 'CI'", gate)
        self.assertEqual(sorted(needs(gate)), ["extensions", "plan", "release-rules", "tests"])
        self.assertIn("!cancelled()", gate)

    def test_the_gate_passes_for_success_and_skipped_and_fails_for_anything_else(self):
        script = run_script(JOBS["ci"])
        for results, required, swift, passes in (("success success success success", "true", "success", True),
                                                ("success success success skipped", "false", "skipped", True),
                                                ("success success success skipped", "true", "skipped", False),
                                                ("success failure success success", "true", "success", False),
                                                ("success success success cancelled", "true", "cancelled", False),
                                                ("failure skipped skipped skipped", "", "skipped", False)):
            done = subprocess.run(["bash", "-c", script], env={"RESULTS": results, "PATH": os.environ["PATH"],
                                                              "SWIFT_REQUIRED": required, "SWIFT_RESULT": swift},
                                  capture_output=True, text=True, timeout=10)
            self.assertEqual(done.returncode == 0, passes, results)

    def test_no_job_may_write_issues_or_contents(self):
        self.assertNotIn("issues: write", WORKFLOW)
        self.assertNotIn("contents: write", WORKFLOW)

    def test_the_swift_job_runs_only_when_the_plan_says_the_change_can_affect_swift(self):
        tests = JOBS["tests"]
        self.assertIn("needs.plan.outputs.swift == 'true'", tests)
        self.assertIn("python3 scripts/ci_plan.py changed.txt", JOBS["plan"])
        self.assertIn("swift: ${{ steps.plan.outputs.swift }}", JOBS["plan"])

    def test_selfhosted_checkout_preserves_build_outputs_without_retaining_git_credentials(self):
        checkout = JOBS["tests"].split("uses: actions/checkout@v4", 1)[1].split("- uses:", 1)[0]
        self.assertIn("clean: ${{ runner.environment != 'self-hosted' }}", checkout)
        self.assertIn("persist-credentials: false", checkout)

    def test_every_script_the_workflow_runs_exists(self):
        for script in set(re.findall(r"scripts/(\w+\.py)", WORKFLOW)):
            self.assertTrue(os.path.exists(os.path.join(ROOT, "scripts", script)), script)

class SwiftBuildActionTests(unittest.TestCase):
    def test_content_hashing_is_required_and_part_of_the_build_marker(self):
        step = ACTION.split("- name: Swift version and flags", 1)[1].split("- name:", 1)[0]
        script = run_script(step)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for name, code in {
                "swiftc": '#!/bin/sh\nprintf "%s\\n" "$SUPPORTED_FLAG"\n',
                "swift": '#!/bin/sh\necho "Swift 6.3 fixture"\n',
                "xcrun": '#!/bin/sh\necho "SDK 26 fixture"\n',
                "xcodebuild": '#!/bin/sh\necho "Xcode 26 fixture"\n',
            }.items():
                program = bin_dir / name
                program.write_text(code)
                program.chmod(0o755)
            env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                   "RUNNER_TEMP": str(root), "GITHUB_ENV": str(root / "env"),
                   "GITHUB_OUTPUT": str(root / "output")}
            def run(code, flag):
                (root / "env").write_text("")
                (root / "output").write_text("")
                result = subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", code],
                                        env={**env, "SUPPORTED_FLAG": flag}, capture_output=True, text=True)
                return result, (root / "env").read_text(), (root / "output").read_text()
            result, flags, marker = run(script, "-enable-incremental-file-hashing")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("-Xswiftc -enable-incremental-file-hashing", flags)
            changed, _, changed_marker = run(script.replace("--disable-index-store", "--different-fixture-flag"),
                                             "-enable-incremental-file-hashing")
            self.assertEqual(changed.returncode, 0, changed.stderr)
            self.assertNotEqual(marker, changed_marker, "compiler options must invalidate cached products")
            unsupported, flags, marker = run(script, "-unrelated-flag")
            self.assertNotEqual(unsupported.returncode, 0)
            self.assertEqual((flags, marker), ("", ""))

    def test_hosted_git_metadata_guard_blocks_credentials_without_disclosing_them(self):
        step = ACTION.split("- name: Guard hosted cache Git metadata", 1)[1].split("- name:", 1)[0]
        self.assertIn("if: runner.environment == 'github-hosted'", step)
        self.assertNotIn("continue-on-error", step)
        self.assertLess(ACTION.index("swift build --build-tests"), ACTION.index("- name: Guard hosted cache Git metadata"))
        self.assertLess(ACTION.index("- name: Guard hosted cache Git metadata"), ACTION.index("uses: actions/cache/save@v4"))
        # Execute the actual inline Python, never Swift or the surrounding build script.
        script = run_script(step).split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        public = '[remote "origin"]\n url = https://github.com/example/public.git\n[core]\n bare = true\n'
        secret = "fixture-private-value"
        cases = [
            (public, True),
            ('[http "https://github.com"]\n extraheader = AUTHORIZATION: basic ' + secret, False),
            ('[HTTP "https://github.com"]\n ExtraHeader = Authorization: Bearer ' + secret, False),
            ('[credential]\n helper = !echo ' + secret, False),
            ('[CrEdEnTiAl "https://github.com"]\n username = ' + secret, False),
            ('[credential]\n helper =\n', False),
            ('[http]\n cookieFile = /scratch/' + secret, False),
            ('[http]\n saveCookies = true\n', False),
            ('[remote "origin"]\n url = https://' + secret + ':password@github.com/example/public.git', False),
            ('[remote "origin"]\n url = https://github.com/example/public.git?access_token=' + secret, False),
            ('[remote "origin"]\n url = https://github.com/example/public.git?API_KEY=' + secret, False),
            ('[remote "origin"]\n url = https://github.com/example/public.git?%74oken=' + secret, False),
            ('[remote "origin"]\n url = https://github.com/example/public.git?to\\\nken=' + secret, False),
            ('[include]\n path = /scratch/' + secret, False),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            # A credential-bearing config outside .build must never be read.
            (root / "config").write_text('[credential]\n helper = ' + secret)
            for location in ("repositories/bare/config", "checkouts/public/.git/config",
                             "checkouts/public/.git/config.worktree"):
                path = root / ".build" / location
                path.parent.mkdir(parents=True, exist_ok=True)
                for case, (text, passes) in enumerate(cases):
                    with self.subTest(location=location, case=case):
                        path.write_text(text)
                        result = subprocess.run([sys.executable, "-c", script], cwd=root,
                                                capture_output=True, text=True, timeout=5)
                        self.assertEqual(result.returncode == 0, passes, result.stdout + result.stderr)
                        self.assertNotIn(secret, result.stdout + result.stderr)
                path.unlink()
            # Public dependency plugins share source directories through ordinary symlinks.
            plugins = root / ".build" / "checkouts" / "public" / "Plugins"
            (plugins / "Shared").mkdir(parents=True)
            (plugins / "Generator").symlink_to("Shared", target_is_directory=True)
            result = subprocess.run([sys.executable, "-c", script], cwd=root,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn(secret, result.stdout + result.stderr)
            # Submodule gitdir files may refer to inspected metadata inside this build root.
            module = root / ".build" / "repositories" / "submodule"
            module.mkdir()
            (module / "config").write_text(public)
            indirect = root / ".build" / "checkouts" / "public" / "Submodule" / ".git"
            indirect.parent.mkdir()
            alias = root / ".build" / "artifacts" / "metadata-link"
            alias.parent.mkdir()
            alias.symlink_to(root, target_is_directory=True)
            for target, passes in ((str(module), True), (os.path.relpath(module, indirect.parent), True),
                                   (str(root / secret), False), (str(alias), False)):
                with self.subTest(gitdir=passes, absolute=os.path.isabs(target)):
                    indirect.write_text("gitdir: " + target + "\n")
                    result = subprocess.run([sys.executable, "-c", script], cwd=root,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode == 0, passes, result.stdout + result.stderr)
                    self.assertNotIn(secret, result.stdout + result.stderr)
            indirect.unlink()
            path = root / ".build" / "repositories" / secret / "config"
            path.parent.mkdir()
            path.write_bytes(b"\xff")
            result = subprocess.run([sys.executable, "-c", script], cwd=root,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(secret, result.stdout + result.stderr)
            path.unlink()
            path.symlink_to(root / "config")
            result = subprocess.run([sys.executable, "-c", script], cwd=root,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(secret, result.stdout + result.stderr)
            path.unlink()
            path.parent.rmdir()
            path.parent.symlink_to(root, target_is_directory=True)
            result = subprocess.run([sys.executable, "-c", script], cwd=root,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(secret, result.stdout + result.stderr)
            path.parent.unlink()
            metadata = root / ".build" / "checkouts" / "public" / ".git"
            metadata.rmdir()
            metadata.symlink_to(root, target_is_directory=True)
            result = subprocess.run([sys.executable, "-c", script], cwd=root,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_clean_or_changed_toolchains_drop_products_but_keep_downloads(self):
        step = ACTION.split("- name: Start over when the toolchain changed", 1)[1].split("- name: Build", 1)[0]
        script = run_script(step)
        for previous, clean, survives in (("current", "false", True), ("old", "false", False),
                                         ("current", "true", False), (None, "false", False)):
            with self.subTest(previous=previous, clean=clean), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                build = root / ".build"
                for name in ("checkouts", "repositories", "artifacts", "pi-engine-cache", "arm64-apple-macosx"):
                    (build / name).mkdir(parents=True)
                    (build / name / "fixture").write_text("keep or rebuild")
                (build / "workspace-state.json").write_text("resolved")
                if previous:
                    (build / "ci-toolchain").write_text(previous + "\n")
                result = subprocess.run(["bash", "-e", "-c", script], cwd=root,
                                        env={**os.environ, "VERSION": "current", "CLEAN": clean},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((build / "arm64-apple-macosx").exists(), survives)
                for name in ("checkouts", "repositories", "artifacts", "pi-engine-cache", "workspace-state.json"):
                    self.assertTrue((build / name).exists(), name)
                self.assertEqual((build / "ci-toolchain").read_text(), "current\n")

class PlanTests(unittest.TestCase):
    def test_docs_templates_and_the_files_other_jobs_cover_run_no_swift(self):
        self.assertFalse(ci_plan.affects_swift([
            "docs/testing.md", "README.md", "AGENTS.md", ".github/pull_request_template.md",
            ".github/workflows/release.yml", ".github/CODEOWNERS",
            "Tests/Extensions/foo.test.mjs", "Tests/Release/test_release.py", "scripts/release.py",
            "App/iOS/App.swift", "App/Info.plist"]))
        self.assertFalse(ci_plan.affects_swift([]))
        # An extension ships in the Swift resource bundle, so its unit check runs (with the node tests).
        filters = ci_plan.filters_for(["Extensions/shepherd-panes.ts"])
        self.assertTrue(filters and all("UnitTests" in f or "Startup" in f or "Identity" in f or "NativeThread" in f for f in filters), filters)

    def test_anything_swift_reads_runs_the_swift_job(self):
        for path in ("Sources/ShepherdApp/Thread.swift", "Tests/ShepherdAppUnitTests/X.swift", "Package.swift",
                     "Package.resolved", ".github/workflows/ci.yml", ".github/actions/swift-build/action.yml",
                     "scripts/pi-engine-pin.json", "scripts/pi_engine.py", "scripts/ci_plan.py",
                     "Tests/Extensions/native-thread-wire.json", "Vendor/x"):
            with self.subTest(path=path):
                self.assertTrue(ci_plan.affects_swift(["docs/x.md", path]))
        self.assertFalse(ci_plan.affects_swift(["Shepherd.xcodeproj/project.pbxproj", "scripts/upload-sentry-symbols.py"]))

    def test_shared_contracts_and_ci_changes_run_all_tests(self):
        for path in ("Sources/ShepherdCore/Agent.swift", "Sources/ShepherdProtocol/Remote.swift",
                     "Tests/ShepherdTestSupport/X.swift", "Package.swift", "Package.resolved",
                     ".github/workflows/ci.yml", ".github/actions/swift-build/action.yml",
                     "scripts/ci_plan.py", "unknown/path"):
            with self.subTest(path=path):
                self.assertEqual(ci_plan.filters_for([path]), [])
        self.assertEqual(ci_plan.filters_for(["Sources/ShepherdApp/Browser.swift"], full=True), [])

    def test_a_source_no_area_claims_runs_its_module_and_the_modules_built_on_it(self):
        cases = (("Sources/ShepherdApp/AgentLayoutDeck.swift", (ci_plan.APP, ci_plan.PREVIEW), (ci_plan.SES,)),
                 ("Packages/ShepherdUI/Sources/ShepherdUI/Tokens.swift", (ci_plan.APP, ci_plan.PREVIEW), (ci_plan.SES,)),
                 ("Sources/ShepherdSessions/SessionServer.swift", (ci_plan.APP, ci_plan.SES, ci_plan.PREVIEW), ()),
                 ("Sources/ShepherdRemote/Thread.swift", (ci_plan.APP, ci_plan.SES, ci_plan.PREVIEW), ()))
        for path, expected, absent in cases:
            with self.subTest(path=path):
                filters = ci_plan.filters_for([path])
                self.assertTrue(filters, "a module path stays selective")
                for pattern in expected:
                    self.assertIn(ci_plan.FAST_ONLY + pattern, filters)
                for pattern in absent:
                    self.assertNotIn(ci_plan.FAST_ONLY + pattern, filters)

    def test_a_selected_run_never_includes_the_deep_suites(self):
        ids = ["ShepherdAppIntegrationTests.ThreadCompletionMatrixTests/a()",
               "ShepherdAppIntegrationTests.ThreadTailFlowTests/b()",
               "ShepherdAppIntegrationTests.DesignPerformanceTests/c()",
               "ShepherdAppIntegrationTests.ThreadTailGuardTests/d()",
               "ShepherdAppIntegrationTests.ThreadScrollingTests/e()",
               "ShepherdAppUnitTests.X/f()",
               "ShepherdPreviewTests.ThreadPreviewTests/g()"] + [f"{name}/h()" for name in ci_plan.SMOKE]
        filters = ci_plan.filters_for(["Sources/ShepherdApp/Thread/ThreadView.swift"])
        pattern = ci_plan.validated_filter(ids, filters)
        self.assertEqual([i for i in ids[:7] if re.search(pattern, i)], ids[3:7])
        # The full lanes and the manual diagnostics still cover them.
        covered = {i for lane in ci_plan.FULL_LANES for i in ids if re.search(ci_plan.FULL_LANES[lane], i)}
        self.assertEqual(covered, set(ids))
        diagnostics = "|".join(f"(?:{f})" for f in ci_plan.UI_DIAGNOSTICS)
        self.assertTrue(re.search(diagnostics, ids[0]))

    def test_feature_runs_keep_units_and_cheap_startup_and_identity_checks(self):
        filters = ci_plan.filters_for(["Sources/ShepherdApp/BrowserHost.swift"])
        for test_id in ("ShepherdCoreUnitTests.AgentTests/model()", "ShepherdUIUnitTests.TokensTests/fonts()",
                        "ShepherdSessionsIntegrationTests.StartupTests/staleStatusesResetToIdle()",
                        "ShepherdSessionsIntegrationTests.ExtensionIdentityTests/aConnectionSpeaksOnlyForItsAgent()",
                        "ShepherdSessionsIntegrationTests.ThreadStartupTests/aPiThatHasNotAnsweredYetIsStartingUntilItServes()"):
            self.assertTrue(any(re.search(pattern, test_id) for pattern in filters), test_id)
        for test_id in ("ShepherdAppIntegrationTests.ThreadCompletionMatrixTests/run()",
                        "DesignSurfaceKitIntegrationTests.DesignBoardViewTests/run()",
                        "ShepherdAppIntegrationTests.SidebarListTests/run()"):
            self.assertFalse(any(re.search(pattern, test_id) for pattern in filters), test_id)

    def test_mixed_features_union_filters_and_include_hidden_layout_regressions(self):
        filters = ci_plan.filters_for(["Sources/ShepherdApp/Thread/ThreadView.swift", "Sources/ShepherdApp/DesignTools.swift"])
        for test_id in ("ShepherdAppIntegrationTests.ThreadScrollingTests/reachingTheTopLoadsOnePageWithoutMovingOrRetrying(fails:)",
                        "ShepherdAppIntegrationTests.IdleCostTests/hiddenLayoutsDrawNoClockFrames()",
                        "ShepherdAppIntegrationTests.ThreadTailGuardTests/a()"):
            self.assertTrue(any(re.search(pattern, test_id) for pattern in filters), test_id)
        self.assertEqual(ci_plan.filters_for(["Sources/ShepherdApp/Browser.swift", "unmapped"]), [])

    def test_module_test_helpers_stay_broad(self):
        self.assertIn(ci_plan.APP, ci_plan.filters_for([
            "Tests/ShepherdAppIntegrationTests/Support/ComposerThread.swift"]))

    def test_every_selected_pattern_must_match_native_test_ids(self):
        ids = ["Module.Suite/a()", "Other.OtherSuite/b()"]
        self.assertEqual(ci_plan.validated_filter(ids, [r"^Module\.", r"^Other\."]), r"(?:^Module\.)|(?:^Other\.)")
        self.assertEqual(ci_plan.validated_filter(ids, [r"^Module\."]), r"(?:^Module\.)")
        for patterns in ([], ["never_matches"], ["^Module", "renamed_suite"], ["("]):
            with self.subTest(patterns=patterns), self.assertRaises((ValueError, re.error)):
                ci_plan.validated_filter(ids, patterns)

    def test_the_workflow_plan_emits_skip_fast_or_full_without_evaluating_paths(self):
        script = run_script(JOBS["plan"])
        fixture = '''git() { printf '%s\\n' "$CHANGED"; }
        python3() { command "$PYTHON" "$PLANNER" "${@:2}"; }
        '''
        cases = (("docs/testing.md", "false", "false", False),
                 ("Sources/ShepherdApp/Browser.swift", "false", "true", True),
                 ("Sources/ShepherdApp/Browser.swift", "true", "true", False),
                 (".github/workflows/ci.yml", "false", "true", False))
        for changed, full, swift, selected in cases:
            with self.subTest(changed=changed, full=full), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                result = subprocess.run(["bash", "-e", "-c", fixture + script], cwd=directory,
                                        env={**os.environ, "EVENT": "pull_request", "FULL": full,
                                             "CHANGED": changed, "DIAGNOSTICS": "none", "GITHUB_OUTPUT": str(output), "PYTHON": sys.executable,
                                             "PLANNER": str(Path(ROOT) / "scripts/ci_plan.py")},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(fields["swift"], swift)
                self.assertEqual(bool(json.loads(fields["filters"])), selected)
                lanes = json.loads(fields["lanes"])
                self.assertEqual(lanes, ["selected"] if swift == "false" or selected else list(ci_plan.FULL_LANES))
                self.assertLessEqual(len(lanes), 4)

    def test_manual_diagnostics_are_fixed_validated_filters_and_never_named_ci(self):
        self.assertIn("options: [none, ui]", WORKFLOW)
        self.assertIn("github.event_name == 'workflow_dispatch' && github.event.inputs.diagnostics == 'ui'", JOBS["ci"])
        self.assertIn("'UI diagnostics' || 'CI'", JOBS["ci"])
        self.assertNotIn("'UI diagnostics' || 'CI'", JOBS["tests"])
        name = re.search(r"name: \$\{\{(.*?)\}\}", JOBS["ci"]).group(1)
        for event in ("pull_request", "push", "schedule", "workflow_dispatch"):
            for diagnostic in ("none", "ui"):
                expression = name.replace("github.event_name", repr(event)).replace("github.event.inputs.diagnostics", repr(diagnostic))
                actual = eval(expression.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}})
                self.assertEqual(actual, "UI diagnostics" if event == "workflow_dispatch" and diagnostic == "ui" else "CI")
        suites = ("ComposerMenuTests", "ThreadCodeBlockTests", "PaneControlTests", "ThreadScrollingTests",
                  "IdleCostTests", "ThreadCompletionMatrixTests", "ThreadCompletionReproductionTests",
                  "RemoteBrowserDriveTests", "ThreadJumpPressTests", "ThreadTailGuardTests",
                  "ThreadTailFlowTests", "ThreadSendScrollTests", "ThreadBlankScreenTests", "DesignPerformanceTests")
        ids = [f"ShepherdAppIntegrationTests.{name}/case()" for name in suites]
        pattern = ci_plan.validated_filter(ids, ci_plan.UI_DIAGNOSTICS)
        self.assertEqual(len(ci_plan.UI_DIAGNOSTICS), len(suites))
        self.assertTrue(all(re.search(pattern, test_id) for test_id in ids))
        self.assertIsNone(re.search(pattern, "ShepherdAppIntegrationTests.UnrelatedTests/case()"))
        script = run_script(JOBS["plan"])
        fixture = 'python3() { command "$PYTHON" "$PLANNER" "${@:2}"; }\n'
        for event, diagnostic, expected in (("workflow_dispatch", "ui", ci_plan.UI_DIAGNOSTICS),
                                            ("workflow_dispatch", "none", []), ("pull_request", "ui", [])):
            with self.subTest(event=event, diagnostic=diagnostic), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                git = 'git() { printf "Package.swift\\n"; }\n'
                result = subprocess.run(["bash", "-e", "-c", fixture + git + script], cwd=directory,
                                        env={**os.environ, "EVENT": event, "DIAGNOSTICS": diagnostic, "FULL": "true",
                                             "GITHUB_OUTPUT": str(output), "PYTHON": sys.executable,
                                             "PLANNER": str(Path(ROOT) / "scripts/ci_plan.py")},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(fields["swift"], "true")
                self.assertEqual(json.loads(fields["filters"]), expected)
                self.assertEqual(json.loads(fields["lanes"]), ["selected"] if expected else list(ci_plan.FULL_LANES))

    def test_filtered_workflow_uses_native_ids_and_keeps_process_errors(self):
        script = run_script(JOBS["tests"].split("- name: Run tests", 1)[1])
        fixture = '''swift() {
          if [ "$2" = list ]; then printf 'Module.Suite/a()\\n'; return 0; fi
          case "$*" in *--filter*) ;; *) return 42;; esac
          echo 'native filtered run'; return "$STATUS"
        }
        '''
        for status in (0, 1, 134):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(["bash", "-e", "-c", fixture + script], cwd=ROOT,
                                        env={**os.environ, "RUNNER_TEMP": directory, "SWIFTPM_FLAGS": "",
                                             "STATUS": str(status), "SWIFT_FILTERS": '["^Module\\\\."]',
                                             "SWIFT_LANE": "selected", "VALIDATE": "--validate"},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn("native filtered run", result.stdout)
                self.assertEqual((Path(directory) / "swift-test.log").read_text(), "native filtered run\n")
                self.assertEqual((Path(directory) / "swift-selected-tests.txt").read_text(), "Module.Suite/a()\n")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["bash", "-e", "-c", fixture + script], cwd=ROOT,
                                    env={**os.environ, "RUNNER_TEMP": directory, "SWIFTPM_FLAGS": "",
                                         "STATUS": "0", "SWIFT_FILTERS": '["missing"]', "SWIFT_LANE": "selected", "VALIDATE": "--validate"},
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no native tests matched", result.stderr)
            self.assertFalse((Path(directory) / "swift-test.log").exists())

    def test_full_workflow_lanes_record_complete_unique_coverage_and_preserve_native_failures(self):
        script = run_script(JOBS["tests"].split("- name: Run tests", 1)[1])
        expected = {
            "thread": ["ShepherdAppIntegrationTests.ThreadTailFlowTests/run()"],
            "features": ["ShepherdAppIntegrationTests.ComposerMenuTests/run()"],
            "app": ["ShepherdAppIntegrationTests.ThreadCompletionReproductionTests/run()"],
            "other": ["NewTarget.Suite/run()", "ShepherdSessionsIntegrationTests.RPCSessionTests/run()"],
        }
        ids = [name for names in expected.values() for name in names]
        fixture = '''swift() {
          if [ "$2" = list ]; then printf '%s\\n' "$TEST_IDS"; return 0; fi
          printf '%s\\n' "$@" > "$RUNNER_TEMP/args"
          echo 'native lane run'; return "$STATUS"
        }
        '''
        for lane, selected in expected.items():
            for status, filters in ((status, filters) for status in (0, 1, 23, 134)
                                    for filters in ([], [r"^(?!NewTarget\.)"])):
                matches = [name for name in selected if not filters or re.search(filters[0], name)]
                with self.subTest(lane=lane, status=status, filters=filters), tempfile.TemporaryDirectory() as directory:
                    result = subprocess.run(["bash", "-eu", "-c", fixture + script], cwd=ROOT,
                                            env={**os.environ, "RUNNER_TEMP": directory, "SWIFTPM_FLAGS": "",
                                                 "TEST_IDS": "\n".join(ids), "SWIFT_FILTERS": json.dumps(filters),
                                                 "SWIFT_LANE": lane, "STATUS": str(status)},
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, status, result.stderr)
                    root = Path(directory)
                    self.assertEqual((root / "swift-selected-tests.txt").read_text().splitlines(), matches)
                    args = (root / "args").read_text().splitlines()
                    pattern = args[args.index("--filter") + 1]
                    self.assertEqual([name for name in ids if re.search(pattern, name)], matches)
                    self.assertEqual((root / "swift-test.log").read_text(), "native lane run\n")

    def test_missing_gui_session_fails_before_compiling_or_testing_on_the_mini(self):
        step = JOBS["tests"].split("- name: Require a logged-in build account for AppKit tests", 1)[1].split("- uses:", 1)[0]
        self.assertIn("if: runner.environment == 'self-hosted'", step)
        script = run_script(step)
        fixture = '''id() { echo 502; }; launchctl() {
          case "$1" in
            print) [ "$2" = gui/502 ] || exit 42; return "$GUI_STATUS";;
            managername) printf '%s\\n' "$MANAGER";;
            *) exit 42;;
          esac
        };\n'''
        for status, manager, expected in ((0, "Aqua", 0), (1, "Aqua", 1), (0, "System", 1), (0, "Background", 1), (0, "", 1)):
            with self.subTest(status=status, manager=manager):
                result = subprocess.run(["bash", "-c", fixture + script],
                                        env={**os.environ, "GUI_STATUS": str(status), "MANAGER": manager},
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                if status:
                    self.assertIn("::error::UI tests need the build account logged into macOS", result.stdout)
                elif expected:
                    self.assertIn("::error::UI tests must run inside the build account GUI session", result.stdout)
        self.assertLess(JOBS["tests"].index("Require a logged-in build account"), JOBS["tests"].index("actions/checkout@v4"))

    def test_the_runner_exit_status_not_printed_fixtures_decides_test_success(self):
        script = run_script(JOBS["tests"].split("- name: Run tests", 1)[1])
        self.assertIn("swift test --no-parallel", script)
        self.assertIn('2>&1 | tee "$RUNNER_TEMP/swift-test.log"', script)
        self.assertIn("set -o pipefail", script)
        fixture = '''swift() {
          if [ "$2" = list ]; then printf 'Module.Suite/a()\\n'; return 0; fi
          echo "Test run with 5 tests failed after 1 second with 1 issue."
          echo "fixture stderr" >&2
          return "$STATUS"
        }\n'''
        for status in (0, 1, 23, 134):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(["bash", "-e", "-c", fixture + script], cwd=ROOT,
                                        env={**os.environ, "RUNNER_TEMP": directory,
                                             "SWIFTPM_FLAGS": "", "STATUS": str(status),
                                             "SWIFT_FILTERS": '["^Module\\\\."]', "SWIFT_LANE": "selected", "VALIDATE": "--validate"},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn("Test run with 5 tests failed", result.stdout)
                self.assertIn("fixture stderr", result.stdout)
                self.assertIn("Native test IDs listed (before filtering): 1", result.stdout)
                self.assertIn(r"(?:^Module\.)", result.stdout)
                self.assertEqual((Path(directory) / "swift-test.log").read_text(),
                                 "Test run with 5 tests failed after 1 second with 1 issue.\nfixture stderr\n")

    def test_a_failed_log_writer_cannot_turn_a_successful_native_run_green(self):
        script = run_script(JOBS["tests"].split("- name: Run tests", 1)[1])
        fixture = 'swift() { echo "Module.Suite/a()"; }; tee() { command tee "$@"; return 7; };\n'
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["bash", "-e", "-c", fixture + script], cwd=ROOT,
                                    env={**os.environ, "RUNNER_TEMP": directory,
                                         "SWIFTPM_FLAGS": "", "SWIFT_FILTERS": '["^Module\\\\."]', "SWIFT_LANE": "selected", "VALIDATE": "--validate"},
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual((Path(directory) / "swift-test.log").read_text(), "Module.Suite/a()\n")


if __name__ == "__main__":
    unittest.main()
