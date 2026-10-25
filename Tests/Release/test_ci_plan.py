"""Protect selective PR coverage without treating filenames as Swift suite names."""
import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_plan


def selected(filters, test_id):
    return not filters or any(re.search(pattern, test_id) for pattern in filters)


class AffectedTestsTests(unittest.TestCase):
    def test_extension_markdown_runs_packaging_tests_but_regular_docs_do_not(self):
        for path in ("Extensions/design-skill/SKILL.md", "Extensions/design-skill/format.md"):
            with self.subTest(path=path):
                self.assertTrue(ci_plan.affects_swift([path]))
                filters = ci_plan.filters_for([path])
                self.assertTrue(selected(filters, "ShepherdAppUnitTests.EmbeddedExtensionTests/bundled()"))
                self.assertTrue(selected(filters, "ShepherdAppIntegrationTests.ExtensionIdentityFlowTests/launch()"))
        self.assertFalse(ci_plan.affects_swift(["docs/design-workflow.md"]))

    def test_a_changed_deep_test_runs_even_in_a_selective_feature_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = "Tests/ShepherdAppIntegrationTests/Reproduction.swift"
            file = root / path
            file.parent.mkdir(parents=True)
            file.write_text("struct ThreadCompletionMatrixTests {\n    @Test func reproduces() {}\n}\n")
            filters = ci_plan.filters_for(["Sources/ShepherdApp/Thread/ThreadView.swift", path], root=root)
            self.assertTrue(selected(filters, "ShepherdAppIntegrationTests.ThreadCompletionMatrixTests/reproduces()"))
            self.assertFalse(selected(filters, "ShepherdAppIntegrationTests.ThreadTailFlowTests/run()"))

    def test_adding_a_feature_regression_does_not_select_unrelated_app_tests(self):
        paths = ["Sources/ShepherdApp/BrowserHost.swift",
                 "Tests/ShepherdAppIntegrationTests/BrowserWebViewTests.swift"]
        filters = ci_plan.filters_for(paths)
        self.assertTrue(filters, "a feature plus its regression must not force a full run")
        for suite in ("BrowserWebViewTests", "RemoteBrowserDrivePolicyTests", "ProjectBrowserControlTests",
                      "MCPCallbackRelayTests"):
            self.assertTrue(selected(filters, f"ShepherdAppIntegrationTests.{suite}/run()"), suite)
        for suite in ("ThreadCompletionMatrixTests", "ThreadCompletionReproductionTests", "ReviewCommitTests"):
            self.assertFalse(selected(filters, f"ShepherdAppIntegrationTests.{suite}/run()"), suite)

    def test_changed_suites_follow_declarations_instead_of_filenames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = "Tests/ShepherdAppIntegrationTests/UnrelatedFilename.swift"
            file = root / path
            file.parent.mkdir(parents=True)
            file.write_text('@Suite("behavior") @MainActor\nstruct FirstTests {\n'
                            '    @Test func works() {}\n}\n'
                            'struct SecondTests {\n    @Test func works() {}\n}\n')
            filters = ci_plan.filters_for([path], root=root)
            for suite in ("FirstTests", "FirstTests.Nested", "SecondTests"):
                self.assertTrue(selected(filters, f"ShepherdAppIntegrationTests.{suite}/works()"), suite)
            self.assertFalse(selected(filters, "ShepherdAppIntegrationTests.UnrelatedTests/works()"))
            self.assertTrue(selected(filters, "ShepherdCoreUnitTests.AgentTests/works()"))
            self.assertTrue(selected(filters, "ShepherdSessionsIntegrationTests.StartupTests/works()"))
            file.write_text(file.read_text() + 'private func localFixture() { let html = """\n'
                            '<p>{ a fake body }</p>\n"""; let expected = #"{"a":1}"# }\n')
            self.assertNotIn(ci_plan.APP, ci_plan.filters_for([path], root=root))

    def test_test_helpers_deletions_and_unfamiliar_shapes_keep_the_module(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = "Tests/ShepherdAppIntegrationTests/OneTests.swift"
            file = root / path
            file.parent.mkdir(parents=True)
            local = "struct OneTests {\n    @Test func works() {}\n}\n"
            for source in (local + "struct SharedFixture {}\n", local + "func sharedFixture() {}\n",
                           local + "protocol FixtureContract {}\n",
                           local + "struct `OtherTests` { @Test func works() {} }\n",
                           local + "    struct OtherSuite { @Test func works() {} }\n",
                           local + "    @Test func extraCoverage() {}\n",
                           local + "@Test private func privateCoverage() {}\n",
                           local + "private struct OtherSuite { @Test func works() {} }\n",
                           local + "fileprivate enum OtherSuite { @Test func works() {} }\n",
                           local + "    struct SharedFixture {}\n",
                           local + "nonisolated(unsafe) var shared = 0\n",
                           local + "infix operator <+> : AdditionPrecedence\n",
                           local + "precedencegroup SharedPrecedence { higherThan: AdditionPrecedence }\n",
                           local + '/* struct Unfinished { */\n',
                           local + 'private let complicated = #"\\#(Shared(\"nested\"))"#\n',
                           local + "struct\nUnfamiliar {}\n",
                           local + '#if DEBUG\n    struct NestedSuite { @Test func works() {} }\n#endif\n',
                           "struct SharedFixture {}\n", "// unfamiliar test declaration\n", None):
                with self.subTest(source=source):
                    if source is None:
                        file.unlink()
                    else:
                        file.write_text(source)
                    self.assertIn(ci_plan.APP, ci_plan.filters_for([path], root=root))
            file.write_text(local)
            (file.parent / "ConsumerTests.swift").write_text(
                "struct ConsumerTests {\n    @Test func works() { OneTests.fixture() }\n}\n")
            self.assertIn(ci_plan.APP, ci_plan.filters_for([path], root=root))
            self.assertIn(ci_plan.APP, ci_plan.filters_for([
                "Tests/ShepherdAppIntegrationTests/Support/FakeHost.swift"], root=root))

    def test_test_selection_does_not_read_linked_source_outside_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            outside = Path(directory) / "outside.swift"
            outside.write_text("struct UnsafeTests {\n    @Test func works() {}\n}\n")
            path = "Tests/ShepherdAppIntegrationTests/Linked.swift"
            file = root / path
            file.parent.mkdir(parents=True)
            file.symlink_to(outside)
            self.assertEqual(ci_plan.test_filter(path, root), ci_plan.APP)

    def test_known_cross_feature_callers_still_run(self):
        cases = (
            ("Sources/ShepherdApp/BrowserHost.swift", "ShepherdAppIntegrationTests.ProjectBrowserControlTests/press()"),
            ("Sources/ShepherdApp/BrowserHost.swift", "ShepherdAppIntegrationTests.MCPCallbackRelayTests/callback()"),
            ("Sources/ShepherdApp/GitWorktree.swift", "ShepherdAppIntegrationTests.NewThreadWorktreeBaseTests/press()"),
            ("Sources/ShepherdApp/GitWorktree.swift", "ShepherdAppIntegrationTests.ListPerformanceTests/rows()"),
            ("Sources/ShepherdApp/CodeHighlight.swift", "ShepherdAppIntegrationTests.ThreadCodeBlockTests/code()"),
            ("Sources/ShepherdApp/CodeHighlight.swift", "ShepherdAppIntegrationTests.ReviewCommitTests/commit()"),
            ("Sources/ShepherdApp/Thread/ModelSettingsPopover.swift", "ShepherdAppIntegrationTests.ModelSettingsPopoverTests/open()"),
            ("Sources/ShepherdApp/Thread/ThreadView.swift", "ShepherdAppIntegrationTests.BlockedModelComposerTests/send()"),
            ("Sources/ShepherdSessions/ServiceTierExtension.swift", "ShepherdSessionsIntegrationTests.ServiceTierTests/patch()"),
            ("Sources/ShepherdSessions/PiSignIn.swift", "ShepherdSessionsIntegrationTests.RPCSessionTests/historyDecodeStillProgressesAfterSignInBridgesAreReleased()"),
            ("Sources/ShepherdApp/SettingsView.swift", "ShepherdAppIntegrationTests.SubagentSettingsControlTests/press()"),
            ("Sources/ShepherdApp/Thread/ThreadView.swift", "ShepherdPreviewTests.ThreadPreviewTests/threadHistoryLayoutMatrix()"),
            ("Sources/ShepherdApp/Thread/ThreadView.swift", "ShepherdAppIntegrationTests.AgentLifecycleTests/send()"),
            ("Sources/ShepherdApp/TerminalHost.swift", "ShepherdAppIntegrationTests.ThreadInputTests/drop()"),
            ("Sources/ShepherdApp/DesignScreen.swift", "ShepherdAppIntegrationTests.ListPerformanceTests/comments()"),
        )
        for path, test_id in cases:
            with self.subTest(path=path, test_id=test_id):
                filters = ci_plan.filters_for([path])
                self.assertTrue(filters, "a mapped feature must stay selective")
                self.assertTrue(selected(filters, test_id))

    def test_shared_boundaries_cannot_silently_narrow_coverage(self):
        for path in ("Sources/ShepherdCore/Models.swift", "Sources/ShepherdProtocol/RemoteMessage.swift",
                     "Sources/shepherd-cli/Main.swift", "Tests/Extensions/native-thread-wire.json",
                     "Tests/ShepherdTestSupport/ScratchServer.swift", "scripts/ci_plan.py",
                     ".github/workflows/ci.yml", "Package.swift", "scripts/pi-engine-pin.json"):
            with self.subTest(path=path):
                self.assertEqual(ci_plan.filters_for([path]), [])
        self.assertEqual(ci_plan.filters_for(["Sources/ShepherdApp/BrowserHost.swift"], full=True), [])

    def test_changed_preview_suite_runs_without_all_native_integrations(self):
        path = "Tests/ShepherdPreviewTests/ProjectBrowserPreviewTests.swift"
        filters = ci_plan.filters_for([path])
        self.assertTrue(selected(filters, "ShepherdPreviewTests.ProjectBrowserPreviewTests/capabilities()"))
        self.assertFalse(selected(filters, "ShepherdAppIntegrationTests.ThreadCompletionMatrixTests/run()"))

    def test_a_stale_declared_suite_mapping_fails_listing_validation(self):
        with self.assertRaisesRegex(ValueError, "no native tests matched"):
            ci_plan.validated_filter(["ShepherdCoreUnitTests.AgentTests/id()"],
                                     [r"^ShepherdAppIntegrationTests\.RemovedTests[./]"])


class FullLaneTests(unittest.TestCase):
    def test_a_broad_module_selection_uses_four_disjoint_filtered_lanes(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = Path(directory) / "changed.txt"
            paths.write_text("Sources/ShepherdSessions/NewFeature.swift\n")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(ci_plan.main(["ci_plan.py", str(paths)]), 0)
            plan = dict(line.split("=", 1) for line in output.getvalue().splitlines())
        self.assertEqual(json.loads(plan["lanes"]), ["thread", "features", "app", "other"])
        filters = json.loads(plan["filters"])
        ids = ["ShepherdAppIntegrationTests.ThreadScrollingTests/scroll()",
               "ShepherdAppIntegrationTests.BrowserWebViewTests/browse()",
               "ShepherdAppIntegrationTests.AgentLifecycleTests/start()",
               "ShepherdAppIntegrationTests.ThreadCompletionMatrixTests/reproduce()",
               "ShepherdCoreUnitTests.AgentTests/id()",
               "ShepherdPreviewTests.ThreadPreviewTests/render()",
               "ShepherdRemoteUnitTests.ClientTests/identity()",
               "DesignSurfaceKitIntegrationTests.DesignBoardViewTests/render()"]
        ids += [f"{suite}/smoke()" for suite in ci_plan.SMOKE]
        covered = []
        for lane in json.loads(plan["lanes"]):
            pattern = ci_plan.validated_lane(ids, lane, filters)
            matches = [name for name in ids if re.search(pattern, name)]
            self.assertTrue(matches, lane)
            covered.extend(matches)
        expected = [name for name in ids if selected(filters, name)]
        self.assertCountEqual(covered, expected)
        self.assertNotIn(ids[3], covered)
        self.assertIn(ids[6], covered)
        self.assertNotIn(ids[7], covered)

    def test_full_lanes_cover_each_native_id_once_and_keep_suites_and_sessions_together(self):
        expected = {
            "thread": ["ShepherdAppIntegrationTests.ThreadCompletionMatrixTests/run()",
                       "ShepherdAppIntegrationTests.ThreadCompletionMatrixTests.Nested/run()",
                       "ShepherdAppIntegrationTests.ThreadTailFlowTests/run()",
                       "ShepherdAppIntegrationTests.ThreadNewUnknownTests/run()"],
            "features": ["ShepherdAppIntegrationTests.ComposerMenuTests/run()",
                         "ShepherdAppIntegrationTests.WorktreeBaseOfflineTests/run()",
                         "ShepherdAppIntegrationTests.BrowserWebViewTests/run()"],
            "app": ["ShepherdAppIntegrationTests.ThreadCompletionReproductionTests/run()",
                    "ShepherdAppIntegrationTests.UnknownSuite/run()"],
            "other": ["ShepherdSessionsIntegrationTests.PiSignInBridgeTests/run()",
                      "ShepherdSessionsIntegrationTests.RPCSessionTests/run()",
                      "ShepherdSessionsIntegrationTests.FutureSuite.Nested/run()",
                      "ShepherdPreviewTests.ThreadPreviewTests/run()",
                      "ShepherdCoreUnitTests.StateTests/run()",
                      "NewModule.UnfamiliarSuite/run()", "NewModule/freeFunction()"],
        }
        ids = [name for names in expected.values() for name in names]
        for lane, names in expected.items():
            pattern = ci_plan.validated_lane(ids, lane)
            self.assertEqual([name for name in ids if re.search(pattern, name)], names)

    def test_bad_inventories_empty_lanes_and_overlap_fail_before_running_any_test(self):
        ids = ["ShepherdAppIntegrationTests.ThreadCompletionMatrixTests/run()",
               "ShepherdAppIntegrationTests.ThreadTailFlowTests/run()",
               "ShepherdAppIntegrationTests.ComposerMenuTests/run()",
               "UnknownModule.Suite/run()"]
        for inventory, lane in (([], "other"), (ids + ids, "other"),
                                (ids + ["unparseable output"], "other"),
                                (ids[:-1], "other"), (ids, "typo")):
            with self.subTest(inventory=inventory, lane=lane), self.assertRaises(ValueError):
                ci_plan.validated_lane(inventory, lane)
        with patch.dict(ci_plan.FULL_LANES, {"other": ".*"}):
            with self.assertRaisesRegex(ValueError, "exactly one lane"):
                ci_plan.validated_lane(ids, "other")


if __name__ == "__main__":
    unittest.main()
