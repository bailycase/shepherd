"""Protect selective PR coverage without treating filenames as Swift suite names."""
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_plan


def selected(filters, test_id):
    return not filters or any(re.search(pattern, test_id) for pattern in filters)


class AffectedTestsTests(unittest.TestCase):
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
                           local + "    struct SharedFixture {}\n",
                           local + "nonisolated(unsafe) var shared = 0\n",
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
            ("Sources/ShepherdSessions/CLIProxyAPI.swift", "ShepherdSessionsIntegrationTests.ServiceTierTests/patch()"),
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

    def test_shared_boundaries_and_unknown_source_cannot_silently_narrow_coverage(self):
        for path in ("Sources/ShepherdCore/Models.swift", "Sources/ShepherdProtocol/RemoteMessage.swift",
                     "Sources/ShepherdSessions/RPCThreadState.swift", "Sources/ShepherdSessions/RPCSession.swift",
                     "Sources/ShepherdSessions/SessionServer+Threads.swift", "Sources/shepherd-cli/Main.swift",
                     "Tests/Extensions/native-thread-wire.json", "Sources/ShepherdApp/NewUnknownView.swift",
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


if __name__ == "__main__":
    unittest.main()
