"""Tests for scripts/ci_impact.py, which decides what a pull request's CI runs.

The map is checked against the real tree: every suite pattern must match a real suite and every
path pattern a real path, so a rename cannot silently narrow a rule. Run:
python3 -m unittest discover -s Tests/Release -v
"""
import json
import os
import re
import subprocess
import sys
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ci_impact  # noqa: E402
import ci_shards  # noqa: E402

TIMES = ci_shards.read_times(os.path.join(ROOT, ci_shards.DEFAULT_TIMES))


def pr(files, base="nightly", labels=()):
    return ci_impact.plan_for(event="pull_request", base_ref=base, ref="refs/pull/1/merge", labels=labels,
                              files=files, root=ROOT, times=TIMES)


def selected(plan):
    return ci_shards.select(sorted(TIMES), plan.selection)


def tracked_files():
    out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
                         capture_output=True, text=True)
    if out.returncode == 0 and out.stdout.strip():
        return out.stdout.splitlines()
    return [os.path.relpath(os.path.join(d, f), ROOT) for d, _, fs in os.walk(ROOT) for f in fs if ".git" not in d]


class MapAgainstTheRealTreeTests(unittest.TestCase):
    def test_every_area_pattern_matches_a_real_suite(self):
        for name, patterns in ci_impact.AREAS.items():
            for pattern in patterns:
                self.assertTrue(any(re.search(pattern, s) for s in TIMES), f"area {name}: {pattern} matches no suite")

    def test_every_smoke_suite_exists(self):
        for suite in ci_impact.SMOKE:
            self.assertIn(suite, TIMES)

    def test_the_smoke_set_is_short(self):
        self.assertLess(sum(TIMES[s] for s in ci_impact.SMOKE), 60)

    def test_every_path_rule_matches_a_real_file(self):
        files = tracked_files()
        for regex, glob, _effect, _why in ci_impact._COMPILED:
            self.assertTrue(any(regex.match(f) for f in files), f"rule {glob} matches no file in the repository")

    def test_every_area_a_rule_names_exists(self):
        for _glob, effect, _why in ci_impact.RULES:
            if isinstance(effect, tuple) and effect[0] == "areas":
                for name in effect[1]:
                    self.assertIn(name, ci_impact.AREAS)

    def test_a_ShepherdApp_file_no_feature_owns_runs_the_whole_app_tier(self):
        plan = pr(["Sources/ShepherdApp/ShepherdViewModel.swift"])
        suites = selected(plan)
        for suite in TIMES:
            if suite.startswith(("ShepherdAppIntegrationTests.", "ShepherdPreviewTests.")):
                self.assertIn(suite, suites)
        self.assertNotIn("ShepherdSessionsIntegrationTests.QueueTests", suites, "the app cannot affect the server's own tests")

    def test_every_real_source_file_has_an_effect(self):
        for path in tracked_files():
            if path.startswith(("Sources/", "Packages/", "Tests/", "Extensions/", "scripts/", "docs/", ".github/")):
                effect, _glob, _why = ci_impact.effect_of(path)
                self.assertIsNotNone(effect, path)


class LaneTests(unittest.TestCase):
    def test_a_docs_only_change_runs_no_swift(self):
        plan = pr(["README.md", "docs/testing.md", "AGENTS.md"])
        self.assertFalse(plan.swift)
        self.assertEqual(plan.outputs()["swift"], "false")

    def test_an_extensions_only_change_runs_no_swift(self):
        plan = pr(["Extensions/shepherd-panes.ts", "Tests/Extensions/terminal-tools.test.mjs"])
        self.assertFalse(plan.swift)

    def test_release_scripts_tests_and_workflow_changes_run_no_swift(self):
        plan = pr(["scripts/release.py", "Tests/Release/test_release.py", ".github/workflows/release.yml",
                   "App/iOS/ShepherdIOSApp.swift", ".github/pull_request_template.md"])
        self.assertFalse(plan.swift)

    def test_a_thread_change_runs_the_unit_tier_the_smoke_set_and_the_thread_suites_only(self):
        plan = pr(["Sources/ShepherdApp/Thread/Composer.swift"])
        self.assertEqual((plan.lane, plan.swift, plan.scope), ("fast", True, "subset"))
        suites = selected(plan)
        self.assertIn("ShepherdAppIntegrationTests.ThreadTailFlowTests", suites)
        self.assertIn("ShepherdAppIntegrationTests.ComposerMenuTests", suites)
        self.assertIn("ShepherdSessionsIntegrationTests.StartupTests", suites, "smoke")
        self.assertIn("ShepherdCoreUnitTests.AgentStatusTests", suites, "unit")
        self.assertNotIn("ShepherdAppIntegrationTests.GitWorktreeTests", suites)
        self.assertNotIn("ShepherdSessionsIntegrationTests.ChangesEngineTests", suites)
        self.assertNotIn("DesignSurfaceKitIntegrationTests.DesignBoardExportTests", suites)

    def test_a_shared_contract_runs_everything(self):
        for path in ("Sources/ShepherdCore/Models.swift", "Sources/ShepherdProtocol/RemoteMessage.swift",
                     "Sources/ShepherdRemote/RemoteHostClient.swift", "Sources/ShepherdSessions/SessionServer.swift",
                     "Package.swift", "Package.resolved", "Shepherd.xcodeproj/project.pbxproj",
                     "Tests/ShepherdTestSupport/ScratchServer.swift", ".github/workflows/ci.yml",
                     ".github/actions/swift-build/action.yml", "scripts/ci_impact.py", "Tests/ci-suite-times.json"):
            plan = pr([path])
            self.assertEqual((plan.swift, plan.scope, plan.shards), (True, "all", ci_impact.FULL_SHARDS), path)

    def test_a_path_the_map_does_not_know_runs_everything(self):
        plan = pr(["something/new/thing.txt"])
        self.assertEqual(plan.scope, "all")
        self.assertIn("does not know", " ".join(plan.reasons))

    def test_one_unknown_path_among_known_ones_runs_everything(self):
        self.assertEqual(pr(["README.md", "mystery.bin"]).scope, "all")

    def test_a_server_change_with_an_owner_runs_that_area_and_not_the_whole_suite(self):
        plan = pr(["Sources/ShepherdSessions/Changes/ChangesService.swift"])
        self.assertEqual(plan.scope, "subset")
        self.assertIn("ShepherdSessionsIntegrationTests.ChangesTurnTests", selected(plan))

    def test_a_package_changing_files_in_two_areas_runs_both(self):
        plan = pr(["Sources/ShepherdApp/BrowserPane.swift", "Sources/ShepherdApp/DiffReview.swift"])
        suites = selected(plan)
        self.assertIn("ShepherdAppIntegrationTests.BrowserAgentTests", suites)
        self.assertIn("ShepherdAppIntegrationTests.ReviewFlowTests", suites)

    def test_a_changed_test_file_runs_the_suites_it_declares(self):
        plan = pr(["Tests/ShepherdAppIntegrationTests/WorktreeTests.swift"])
        suites = selected(plan)
        for name in ("GitWorktreeTests", "FinalizeWorktreeTests", "WorktreeAgentTests"):
            self.assertIn(f"ShepherdAppIntegrationTests.{name}", suites)
        self.assertNotIn("ShepherdAppIntegrationTests.ThreadTailFlowTests", suites)

    def test_a_test_helper_runs_its_whole_target(self):
        plan = pr(["Tests/ShepherdAppIntegrationTests/Support/ListFixtures.swift"])
        suites = selected(plan)
        self.assertIn("ShepherdAppIntegrationTests.ThreadTailFlowTests", suites)
        self.assertNotIn("ShepherdSessionsIntegrationTests.QueueTests", suites)

    def test_a_changed_unit_test_runs_only_the_unit_tier_and_smoke(self):
        plan = pr(["Tests/ShepherdRemoteUnitTests/QuestionDockTests.swift"])
        self.assertEqual((plan.swift, plan.scope, plan.shards), (True, "subset", 1))
        self.assertEqual(plan.selection["regexes"], [])

    def test_a_deleted_test_file_needs_only_the_build(self):
        plan = pr(["Tests/ShepherdAppIntegrationTests/GoneTests.swift"])
        self.assertEqual(plan.selection["regexes"] + plan.selection["suites"], [])

    def test_an_embedded_extension_literal_runs_the_unit_tier_for_its_identity_test(self):
        plan = pr(["Sources/ShepherdApp/PanesExtension.swift", "Extensions/shepherd-panes.ts"])
        self.assertTrue(plan.swift)
        self.assertEqual(plan.selection["regexes"], [])

    def test_the_embedded_mcp_client_runs_the_settings_suites_that_run_it(self):
        plan = pr(["Sources/ShepherdApp/MCPExtension.swift"])
        self.assertIn("ShepherdAppIntegrationTests.MCPEndToEndTests", selected(plan))

    def test_the_cli_runs_only_its_unit_tests(self):
        plan = pr(["Sources/shepherd-cli/main.swift"])
        self.assertEqual(plan.selection["regexes"], [])

    def test_shared_ui_runs_the_apps_integration_tier_but_not_the_servers(self):
        plan = pr(["Packages/ShepherdUI/Sources/ShepherdUI/Tokens/Colors.swift"])
        suites = selected(plan)
        self.assertIn("ShepherdAppIntegrationTests.WorkspaceNavigationTests", suites)
        self.assertNotIn("ShepherdSessionsIntegrationTests.QueueTests", suites)

    def test_every_plan_that_runs_swift_keeps_the_smoke_set(self):
        for files in (["Sources/ShepherdApp/Thread/Composer.swift"], ["Sources/shepherd-cli/main.swift"], ["Tests/ShepherdCoreUnitTests/X.swift"]):
            plan = pr(files)
            self.assertEqual(plan.selection["smoke"], ci_impact.SMOKE)
            self.assertTrue(plan.selection["unit"])

    def test_the_fast_lane_uses_more_shards_for_more_tests_and_never_more_than_the_full_lane(self):
        self.assertEqual(ci_impact.fast_shards(40), 1)
        self.assertEqual(ci_impact.fast_shards(201), 2)
        self.assertEqual(ci_impact.fast_shards(10_000), ci_impact.FULL_SHARDS)


class EventTests(unittest.TestCase):
    def plan(self, **kw):
        return ci_impact.plan_for(root=ROOT, times=TIMES, **kw)

    def test_a_pull_request_into_master_runs_the_full_lane(self):
        plan = pr(["README.md"], base="master")
        self.assertEqual((plan.lane, plan.scope, plan.swift), ("full", "all", True))
        self.assertFalse(plan.shared_build)
        self.assertFalse(plan.report)

    def test_the_full_ci_label_runs_the_full_lane(self):
        plan = pr(["README.md"], labels=("bug", "full-ci"))
        self.assertEqual((plan.lane, plan.scope), ("full", "all"))
        self.assertIn("full-ci", plan.reasons[0])

    def test_other_labels_do_not(self):
        self.assertEqual(pr(["README.md"], labels=("bug",)).swift, False)

    def test_a_push_to_nightly_runs_the_full_lane_builds_once_and_reports(self):
        plan = self.plan(event="push", ref="refs/heads/nightly")
        self.assertEqual((plan.lane, plan.scope, plan.shared_build, plan.report, plan.repeat), ("full", "all", True, True, 1))

    def test_a_push_to_a_branch_that_is_not_nightly_or_master_does_not_report(self):
        plan = self.plan(event="push", ref="refs/heads/feat/x")
        self.assertFalse(plan.report)

    def test_the_daily_run_is_a_three_pass_full_lane_on_nightly(self):
        plan = self.plan(event="schedule", ref="refs/heads/master")
        self.assertEqual((plan.lane, plan.repeat, plan.report, plan.clean, plan.checkout_ref), ("full", 3, True, True, "nightly"))

    def test_a_manual_run_defaults_to_the_full_lane(self):
        plan = self.plan(event="workflow_dispatch", ref="refs/heads/ci/x", dispatch_lane="auto")
        self.assertEqual((plan.lane, plan.scope), ("full", "all"))
        self.assertFalse(plan.report, "only nightly and master runs file issues")

    def test_a_manual_fast_run_with_files_picks_a_subset(self):
        plan = self.plan(event="workflow_dispatch", ref="refs/heads/ci/x", dispatch_lane="fast",
                         files=["Sources/ShepherdApp/BrowserPane.swift"])
        self.assertEqual((plan.lane, plan.scope), ("fast", "subset"))

    def test_a_manual_fast_run_without_a_diff_takes_the_full_lane(self):
        plan = self.plan(event="workflow_dispatch", ref="refs/heads/ci/x", dispatch_lane="fast", files=None)
        self.assertEqual(plan.scope, "all")

    def test_a_manual_flake_hunt_runs_three_passes(self):
        plan = self.plan(event="workflow_dispatch", ref="refs/heads/nightly", dispatch_lane="flake-hunt")
        self.assertEqual((plan.repeat, plan.report), (3, True))

    def test_shared_build_can_be_switched_off_by_a_manual_run(self):
        plan = self.plan(event="push", ref="refs/heads/nightly", shared_build=False)
        self.assertFalse(plan.shared_build)


class OutputTests(unittest.TestCase):
    def test_the_outputs_are_what_the_workflow_reads(self):
        out = pr(["Sources/ShepherdApp/Thread/Composer.swift"]).outputs()
        self.assertEqual(set(out), {"lane", "swift", "scope", "selection", "shards", "repeat", "shared_build",
                                    "report", "clean", "checkout_ref"})
        shards = json.loads(out["shards"])
        self.assertTrue(all(s["id"].endswith(f"/{len(shards)}") for s in shards))
        self.assertTrue(all("/" not in s["slug"] for s in shards), "an artifact name cannot hold a slash")
        self.assertTrue(json.loads(out["selection"])["unit"])

    def test_a_run_without_swift_still_has_one_harmless_matrix_entry(self):
        out = pr(["README.md"]).outputs()
        self.assertEqual(json.loads(out["shards"]), [{"id": "1/1", "slug": "1of1"}])

    def test_the_summary_says_what_ran_and_why(self):
        plan = pr(["Sources/ShepherdApp/Thread/Composer.swift", "README.md"])
        text = ci_impact.summary(plan, TIMES)
        self.assertIn("A subset runs", text)
        self.assertIn("`Sources/ShepherdApp/Thread/Composer.swift`", text)
        self.assertIn("the thread suites", text)
        self.assertIn("`README.md`: no Swift tests", text)
        self.assertIn("full-ci", text)

    def test_the_summary_of_an_everything_run_names_the_path_that_asked_for_it(self):
        text = ci_impact.summary(pr(["Sources/ShepherdCore/Models.swift"]), TIMES)
        self.assertIn("Everything runs", text)
        self.assertIn("`Sources/ShepherdCore/Models.swift` is a shared contract", text)


class GlobTests(unittest.TestCase):
    def test_star_stays_in_a_folder_and_double_star_crosses_them(self):
        self.assertTrue(ci_impact.glob_regex("docs/**").match("docs/design/a.md"))
        self.assertTrue(ci_impact.glob_regex("**/*.md").match("README.md"))
        self.assertTrue(ci_impact.glob_regex("**/*.md").match("a/b/C.md"))
        self.assertTrue(ci_impact.glob_regex("Sources/ShepherdApp/*Extension.swift").match("Sources/ShepherdApp/PanesExtension.swift"))
        self.assertFalse(ci_impact.glob_regex("Sources/ShepherdApp/*.swift").match("Sources/ShepherdApp/Thread/Composer.swift"))
        self.assertFalse(ci_impact.glob_regex("App/*.icon/**").match("App/iOS/x"))

    def test_a_dot_in_a_pattern_is_a_dot(self):
        self.assertFalse(ci_impact.glob_regex("Package.swift").match("PackageXswift"))


if __name__ == "__main__":
    unittest.main()
