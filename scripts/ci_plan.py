#!/usr/bin/env python3
"""Select native Swift test filters for ordinary nightly PRs; shared/unknown paths run all.

ci_plan.py changed.txt [--full] prints GitHub outputs, swift and filters.
ci_plan.py --validate test-list.txt '<filters JSON>' checks native matches and prints a regex.
"""
from __future__ import annotations

import fnmatch
import json
from pathlib import Path
import re
import sys

# `*` crosses folders: these patterns name whole trees and extensions.
NO_SWIFT = (
    "docs/*", "*.md", "LICENSE",
    ".github/ISSUE_TEMPLATE/*", ".github/pull_request_template.md",
    ".github/workflows/release.yml", ".github/workflows/release-build.yml", ".github/workflows/pr-body.yml",
    ".github/CODEOWNERS",
    "App/iOS/*", "Tests/ShepherdIOSChecks/*", "App/Info.plist", "App/*.icon/*", "App/*.entitlements",
    "App/ShepherdLauncher.swift",
    "Extensions/*", "Tests/Extensions/*.mjs", "Tests/Extensions/fixtures/*", "Tests/Release/*",
    "scripts/release*.py", "scripts/sign-*.sh", "scripts/check_pr_body.py", "scripts/design_section.py",
    "scripts/context-budget.json", "scripts/sync-embedded-extension.py", "scripts/test-browser-persistence.py",
)

# This mandatory smoke set preserves the previous fast PR gate, including RPC child commands.
SMOKE = (
    "ShepherdSessionsIntegrationTests.StartupTests",
    "ShepherdSessionsIntegrationTests.StateMutationTests",
    "ShepherdSessionsIntegrationTests.ExtensionIdentityTests",
    "ShepherdSessionsIntegrationTests.RemoteListenerTests",
    "ShepherdSessionsIntegrationTests.ThreadStartupTests",
    "ShepherdSessionsIntegrationTests.NativeThreadTests",
    "ShepherdAppIntegrationTests.AgentLifecycleTests",
    "ShepherdAppIntegrationTests.ExtensionIdentityFlowTests",
    "ShepherdAppIntegrationTests.NewThreadComposerTests",
    "ShepherdAppIntegrationTests.SidebarListTests",
    "ShepherdAppIntegrationTests.ThreadInputTests",
    "ShepherdAppIntegrationTests.TerminalSessionStoreTests",
    "DesignSurfaceKitIntegrationTests.DesignBoardViewTests",
)
APP = r"^ShepherdAppIntegrationTests\."
SES = r"^ShepherdSessionsIntegrationTests\."

# Short, conservative feature rules. A path not claimed here or by a module below runs all.
AREAS = (
    (("Sources/ShepherdApp/Thread/*", "Sources/ShepherdApp/ThreadHeader.swift",
      "Sources/ShepherdApp/NativeThreadStores*.swift", "Sources/ShepherdApp/NewThread*.swift",
      "Sources/ShepherdApp/AgentBanners.swift", "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/*",
      "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/*"),
     (APP + r"(Thread|Composer|QueueStack|QuestionDock|ProseImage|NewThread|MotionProbe|ServiceTier|ControlMotion|ModelCatalog|ListPerformance|HiddenAgents|SubagentMotion|IdleCost)",)),
    (("Sources/ShepherdApp/Browser*.swift", "Sources/ShepherdApp/ShepherdViewModel+Browser*.swift",
      "Sources/ShepherdSessions/BrowserTunnelHost.swift", "Packages/ShepherdUI/Sources/ShepherdUI/Components/Browser/*"),
     (APP + r"(Browser|RemoteBrowser)", SES + "Browser")),
    (("Sources/ShepherdApp/Design*.swift", "Sources/ShepherdApp/NewDesignPage.swift",
      "Sources/ShepherdApp/RemoteDesigns.swift", "Sources/ShepherdApp/ShepherdViewModel+Design*.swift",
      "Sources/ShepherdApp/NightWatchSystem.swift", "Sources/ShepherdApp/ImplementSheet.swift",
      "Sources/ShepherdSessions/Design*.swift", "Sources/ShepherdSessions/RemoteDesigns.swift",
      "Sources/DesignSurfaceKit/*", "Tests/Designs/*", "Packages/ShepherdUI/Sources/ShepherdUI/Components/DesignTool/*"),
     (APP + r"(Design|RemoteDesignFlow)", SES + r"(Design|RemoteDesign)", r"^DesignSurfaceKitIntegrationTests\.")),
    (("Sources/ShepherdApp/DiffReview*.swift", "Sources/ShepherdApp/Changes*.swift",
      "Sources/ShepherdApp/*Worktree*.swift", "Sources/ShepherdApp/ReviewCommit*.swift",
      "Sources/ShepherdApp/ShepherdViewModel+Review*.swift", "Sources/ShepherdApp/GitDiff.swift",
      "Sources/ShepherdApp/CodeHighlight.swift", "Sources/ShepherdApp/SplitDiffWheelReader.swift",
      "Sources/ShepherdApp/ChecklistStatus.swift", "Sources/ShepherdApp/CheckoutMonitor.swift",
      "Sources/ShepherdSessions/Changes/*", "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/*"),
     (APP + r"(Review|DiffDrawing|GitDiff|GitWorktree|FinalizeWorktree|RemoteWorktree|WorktreeAgent|WorktreeBaseOffline|CheckoutMonitor)", SES + "Changes")),
    (("Sources/ShepherdApp/Terminal*.swift", "Sources/ShepherdApp/PaneControl.swift", "Sources/ShepherdApp/PaneFocusMemory.swift",
      "Sources/ShepherdApp/ShellIntegration.swift", "Sources/ShepherdApp/ShepherdViewModel+Terminal.swift",
      "Sources/TerminalSurfaceKit/*", "Packages/ShepherdUI/Sources/ShepherdUI/Components/Terminal/*"),
     (APP + r"(Terminal|ShellTerminalMotion|Pane|LoginShell|ShellIntegration|ThreadTailFlow|IdleCost)",)),
    (("Sources/ShepherdApp/Sidebar*.swift", "Sources/ShepherdApp/Workspace*.swift", "Sources/ShepherdApp/Pages/*"),
     (APP + r"(Sidebar|Workspace|ShellMotion|RightPaneMotion|PaletteMotion|SettingsMotion|Space|AgentStartup|AgentLifecycle|AgentLaunch|AgentPeerDeletion|AgentStartProblem|IdleCost|ListPerformance|HiddenAgents|InstructionsEditor|ServerStartupRefusal|Thread)",)),
    (("Sources/ShepherdApp/Settings*.swift", "Sources/ShepherdApp/MCP/*", "Sources/ShepherdApp/Pi*.swift",
      "Sources/ShepherdApp/YourPi*.swift", "Sources/ShepherdApp/Instructions*.swift", "Sources/ShepherdApp/Suggestions*.swift",
      "Sources/ShepherdApp/Skills*.swift", "Sources/ShepherdSessions/Skills*.swift",
      "Sources/ShepherdSessions/Suggestions*.swift", "Sources/ShepherdSessions/Instructions*.swift",
      "Sources/ShepherdSessions/YourPi*.swift", "Sources/ShepherdSessions/PiSignIn*.swift",
      "Sources/ShepherdSessions/CLIProxyAPI*.swift", "Packages/ShepherdUI/Sources/ShepherdUI/Components/Settings/*",
      "Packages/ShepherdUI/Sources/ShepherdUI/Components/Skills/*", "Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/*"),
     (APP + r"(MCP|PiSignIn|PiHomeLaunch|YourPi|SettingsReset|SettingsMotion|InstructionsEditor|ModelCatalog)",
      SES + r"(MCP|PiLauncher|PiSignIn|YourPi|Skills|Suggestions|CLIProxyAPI|RemoteSkills|RemoteInstructions|RemoteHostSettings|StartProblem)")),
    (("Sources/ShepherdApp/Pages/*", "Sources/ShepherdApp/Remote*.swift", "Sources/ShepherdApp/RemoteHostStore.swift",
      "Sources/ShepherdSessions/AutomationRuns.swift", "Packages/ShepherdUI/Sources/ShepherdUI/Components/Automations/*"),
     (APP + r"(Automations|LocalAutomation|RemoteAutomations|RemoteHost|RemotePaneStream|RemoteThreadMount|Sidebar|Workspace)",
      SES + r"(Automation|RemoteAutomation|RemoteListener|RemoteSession|RemoteControl)")),
)
TEST_MODULES = ("ShepherdAppIntegrationTests", "ShepherdSessionsIntegrationTests", "ShepherdRemoteIntegrationTests",
                "DesignSurfaceKitIntegrationTests", "ShepherdPreviewTests")


def affects_swift(paths: list[str]) -> bool:
    return any(not any(fnmatch.fnmatchcase(path, p) for p in NO_SWIFT) for path in paths)


def filters_for(paths: list[str], full: bool = False) -> list[str]:
    """An empty list means all tests, never an empty test run."""
    if full:
        return []
    filters = [r"^[^.]*UnitTests\."] + ["^" + re.escape(name) + r"[./]" for name in SMOKE]
    for path in paths:
        if not affects_swift([path]):
            continue
        if (fnmatch.fnmatchcase(path, "Sources/ShepherdApp/*Extension.swift") or path.startswith("Sources/shepherd-cli/")
                or path in ("Tests/Extensions/native-thread-wire.json", "Tests/Extensions/service-tier-support.json")):
            continue
        matching = [suites for patterns, suites in AREAS if any(fnmatch.fnmatchcase(path, p) for p in patterns)]
        if matching:
            filters.extend(suite for suites in matching for suite in suites)
        elif path.startswith("Tests/") and len(path.split("/")) > 2:
            module = path.split("/")[1]
            if module in TEST_MODULES:
                filters.append("^" + re.escape(module) + r"\.")
            elif not module.endswith("UnitTests"):
                return []
        elif path.startswith(("Sources/ShepherdApp/", "Packages/ShepherdUI/Sources/ShepherdUI/")):
            filters.extend((APP, r"^ShepherdPreviewTests\."))
        else:
            return []
    return list(dict.fromkeys(filters))


def validated_filter(test_ids: list[str], filters: list[str]) -> str:
    if not filters:
        raise ValueError("filtered runs require at least one suite pattern")
    for pattern in filters:
        if not any(re.search(pattern, test_id) for test_id in test_ids):
            raise ValueError(f"no native tests matched {pattern!r}")
    return "|".join(f"(?:{pattern})" for pattern in filters)


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 4 and argv[1] == "--validate":
            print(validated_filter(Path(argv[2]).read_text().splitlines(), json.loads(argv[3])))
            return 0
        if len(argv) not in (2, 3) or (len(argv) == 3 and argv[2] != "--full"):
            sys.stderr.write(__doc__)
            return 2
        paths = [line.strip() for line in Path(argv[1]).read_text().splitlines() if line.strip()]
        print("swift=" + str(affects_swift(paths)).lower())
        print("filters=" + json.dumps(filters_for(paths, full=len(argv) == 3) if affects_swift(paths) else [], separators=(",", ":")))
        return 0
    except (OSError, ValueError, re.error) as error:
        sys.stderr.write(f"CI planning failed: {error}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
