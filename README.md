# Sidebar status-group evidence

Source commit: [`12bf20aa`](https://github.com/bailycase/shepherd/commit/12bf20aace34a3e3537cd5c903b034666ef863eb).

These are native SwiftUI/AppKit screenshots from the implementation, not redraws of the supplied design. Fixture state goes through the real view model, completion tracking, pinning and sidebar projection. Full-window images use an in-process host and stub pi. No production state or real provider turns.

84 unmodified PNGs. `manifest.json` records their dimensions, SHA-256 checksums, source commit and validation commands. This evidence branch is not intended to merge into Nightly.

## Activity states

| State | Light | Dark |
| --- | --- | --- |
| All groups expanded | <img src="renders/sidebar-activity-full-light.png" alt="All groups expanded in light" width="232"> | <img src="renders/sidebar-activity-full-dark.png" alt="All groups expanded in dark" width="232"> |
| Working, Recents and Designs folded independently | <img src="renders/sidebar-activity-collapsed-light.png" alt="Working, Recents and Designs folded independently in light" width="232"> | <img src="renders/sidebar-activity-collapsed-dark.png" alt="Working, Recents and Designs folded independently in dark" width="232"> |
| Every group folded; counts and Working running dot remain | <img src="renders/sidebar-activity-allCollapsed-light.png" alt="Every group folded; counts and Working running dot remain in light" width="232"> | <img src="renders/sidebar-activity-allCollapsed-dark.png" alt="Every group folded; counts and Working running dot remain in dark" width="232"> |
| Done folded; Mark all seen remains available | <img src="renders/sidebar-activity-doneCollapsed-light.png" alt="Done folded; Mark all seen remains available in light" width="232"> | <img src="renders/sidebar-activity-doneCollapsed-dark.png" alt="Done folded; Mark all seen remains available in dark" width="232"> |
| Reading Done; the selected completion stays in Done | <img src="renders/sidebar-activity-selectedDone-light.png" alt="Reading Done; the selected completion stays in Done in light" width="232"> | <img src="renders/sidebar-activity-selectedDone-dark.png" alt="Reading Done; the selected completion stays in Done in dark" width="232"> |
| Opening another thread; read completion moves to Recents, Done count falls | <img src="renders/sidebar-activity-afterReadingDone-light.png" alt="Opening another thread; read completion moves to Recents, Done count falls in light" width="232"> | <img src="renders/sidebar-activity-afterReadingDone-dark.png" alt="Opening another thread; read completion moves to Recents, Done count falls in dark" width="232"> |
| After Mark all seen; Done disappears and cleared rows join Recents | <img src="renders/sidebar-activity-nodone-light.png" alt="After Mark all seen; Done disappears and cleared rows join Recents in light" width="232"> | <img src="renders/sidebar-activity-nodone-dark.png" alt="After Mark all seen; Done disappears and cleared rows join Recents in dark" width="232"> |
| Empty workspace; no activity headers | <img src="renders/sidebar-activity-empty-light.png" alt="Empty workspace; no activity headers in light" width="232"> | <img src="renders/sidebar-activity-empty-dark.png" alt="Empty workspace; no activity headers in dark" width="232"> |
| Long thread and design titles | <img src="renders/sidebar-activity-long-light.png" alt="Long thread and design titles in light" width="232"> | <img src="renders/sidebar-activity-long-dark.png" alt="Long thread and design titles in dark" width="232"> |

## Activity states at text scale 1.3

| State | Light | Dark |
| --- | --- | --- |
| All groups expanded | <img src="renders/sidebar-activity-full-x1.3-light.png" alt="All groups expanded in light" width="232"> | <img src="renders/sidebar-activity-full-x1.3-dark.png" alt="All groups expanded in dark" width="232"> |
| Working, Recents and Designs folded independently | <img src="renders/sidebar-activity-collapsed-x1.3-light.png" alt="Working, Recents and Designs folded independently in light" width="232"> | <img src="renders/sidebar-activity-collapsed-x1.3-dark.png" alt="Working, Recents and Designs folded independently in dark" width="232"> |
| Every group folded; counts and Working running dot remain | <img src="renders/sidebar-activity-allCollapsed-x1.3-light.png" alt="Every group folded; counts and Working running dot remain in light" width="232"> | <img src="renders/sidebar-activity-allCollapsed-x1.3-dark.png" alt="Every group folded; counts and Working running dot remain in dark" width="232"> |
| Done folded; Mark all seen remains available | <img src="renders/sidebar-activity-doneCollapsed-x1.3-light.png" alt="Done folded; Mark all seen remains available in light" width="232"> | <img src="renders/sidebar-activity-doneCollapsed-x1.3-dark.png" alt="Done folded; Mark all seen remains available in dark" width="232"> |
| Reading Done; the selected completion stays in Done | <img src="renders/sidebar-activity-selectedDone-x1.3-light.png" alt="Reading Done; the selected completion stays in Done in light" width="232"> | <img src="renders/sidebar-activity-selectedDone-x1.3-dark.png" alt="Reading Done; the selected completion stays in Done in dark" width="232"> |
| Opening another thread; read completion moves to Recents, Done count falls | <img src="renders/sidebar-activity-afterReadingDone-x1.3-light.png" alt="Opening another thread; read completion moves to Recents, Done count falls in light" width="232"> | <img src="renders/sidebar-activity-afterReadingDone-x1.3-dark.png" alt="Opening another thread; read completion moves to Recents, Done count falls in dark" width="232"> |
| After Mark all seen; Done disappears and cleared rows join Recents | <img src="renders/sidebar-activity-nodone-x1.3-light.png" alt="After Mark all seen; Done disappears and cleared rows join Recents in light" width="232"> | <img src="renders/sidebar-activity-nodone-x1.3-dark.png" alt="After Mark all seen; Done disappears and cleared rows join Recents in dark" width="232"> |
| Empty workspace; no activity headers | <img src="renders/sidebar-activity-empty-x1.3-light.png" alt="Empty workspace; no activity headers in light" width="232"> | <img src="renders/sidebar-activity-empty-x1.3-dark.png" alt="Empty workspace; no activity headers in dark" width="232"> |
| Long thread and design titles | <img src="renders/sidebar-activity-long-x1.3-light.png" alt="Long thread and design titles in light" width="232"> | <img src="renders/sidebar-activity-long-x1.3-dark.png" alt="Long thread and design titles in dark" width="232"> |

## Pinned, densities, failure states, remote, Projects and full windows

| State | Light | Dark |
| --- | --- | --- |
| The same pinned thread while idle | <img src="renders/sidebar-pinned-idle-light.png" alt="The same pinned thread while idle in light" width="232"> | <img src="renders/sidebar-pinned-idle-dark.png" alt="The same pinned thread while idle in dark" width="232"> |
| The same pinned thread while working | <img src="renders/sidebar-pinned-working-light.png" alt="The same pinned thread while working in light" width="232"> | <img src="renders/sidebar-pinned-working-dark.png" alt="The same pinned thread while working in dark" width="232"> |
| The same pinned thread while asking, with its reason | <img src="renders/sidebar-pinned-blocked-light.png" alt="The same pinned thread while asking, with its reason in light" width="232"> | <img src="renders/sidebar-pinned-blocked-dark.png" alt="The same pinned thread while asking, with its reason in dark" width="232"> |
| The same pinned thread when done | <img src="renders/sidebar-pinned-done-light.png" alt="The same pinned thread when done in light" width="232"> | <img src="renders/sidebar-pinned-done-dark.png" alt="The same pinned thread when done in dark" width="232"> |
| Multiple pins retain pin order and contain the asking thread | <img src="renders/sidebar-pinned-light.png" alt="Multiple pins retain pin order and contain the asking thread in light" width="232"> | <img src="renders/sidebar-pinned-dark.png" alt="Multiple pins retain pin order and contain the asking thread in dark" width="232"> |
| Command-digit hints follow visible pinned and activity rows | <img src="renders/sidebar-pinned-digits-light.png" alt="Command-digit hints follow visible pinned and activity rows in light" width="232"> | <img src="renders/sidebar-pinned-digits-dark.png" alt="Command-digit hints follow visible pinned and activity rows in dark" width="232"> |
| Compact density, 22pt thread rows and 24pt minimum header hit areas | <img src="renders/sidebar-compact-light.png" alt="Compact density, 22pt thread rows and 24pt minimum header hit areas in light" width="232"> | <img src="renders/sidebar-compact-dark.png" alt="Compact density, 22pt thread rows and 24pt minimum header hit areas in dark" width="232"> |
| Standard density, 28pt thread rows | <img src="renders/sidebar-standard-light.png" alt="Standard density, 28pt thread rows in light" width="232"> | <img src="renders/sidebar-standard-dark.png" alt="Standard density, 28pt thread rows in dark" width="232"> |
| Comfortable density, 36pt thread rows | <img src="renders/sidebar-comfortable-light.png" alt="Comfortable density, 36pt thread rows in light" width="232"> | <img src="renders/sidebar-comfortable-dark.png" alt="Comfortable density, 36pt thread rows in dark" width="232"> |
| Question reasons and fallback text | <img src="renders/sidebar-needs-you-reasons-light.png" alt="Question reasons and fallback text in light" width="232"> | <img src="renders/sidebar-needs-you-reasons-dark.png" alt="Question reasons and fallback text in dark" width="232"> |
| Running, asking and settled automation rows | <img src="renders/sidebar-automations-light.png" alt="Running, asking and settled automation rows in light" width="232"> | <img src="renders/sidebar-automations-dark.png" alt="Running, asking and settled automation rows in dark" width="232"> |
| Cannot start, with the red state and trailing reason | <img src="renders/sidebar-cannot-start-light.png" alt="Cannot start, with the red state and trailing reason in light" width="232"> | <img src="renders/sidebar-cannot-start-dark.png" alt="Cannot start, with the red state and trailing reason in dark" width="232"> |
| Waiting for import and not signed in | <img src="renders/sidebar-waiting-and-sign-in-light.png" alt="Waiting for import and not signed in in light" width="232"> | <img src="renders/sidebar-waiting-and-sign-in-dark.png" alt="Waiting for import and not signed in in dark" width="232"> |
| Hosts destination with its offline count | <img src="renders/sidebar-more-hosts-light.png" alt="Hosts destination with its offline count in light" width="232"> | <img src="renders/sidebar-more-hosts-dark.png" alt="Hosts destination with its offline count in dark" width="232"> |
| Remote activity rows retain host tags | <img src="renders/sidebar-remote-threads-light.png" alt="Remote activity rows retain host tags in light" width="232"> | <img src="renders/sidebar-remote-threads-dark.png" alt="Remote activity rows retain host tags in dark" width="232"> |
| Projects organization, Standard density | <img src="renders/sidebar-projects-standard-light.png" alt="Projects organization, Standard density in light" width="232"> | <img src="renders/sidebar-projects-standard-dark.png" alt="Projects organization, Standard density in dark" width="232"> |
| Projects organization, Compact density | <img src="renders/sidebar-projects-compact-light.png" alt="Projects organization, Compact density in light" width="232"> | <img src="renders/sidebar-projects-compact-dark.png" alt="Projects organization, Compact density in dark" width="232"> |
| Several open projects | <img src="renders/sidebar-projects-open-light.png" alt="Several open projects in light" width="232"> | <img src="renders/sidebar-projects-open-dark.png" alt="Several open projects in dark" width="232"> |
| Projects organized by host, including unreachable host | <img src="renders/sidebar-projects-by-host-light.png" alt="Projects organized by host, including unreachable host in light" width="232"> | <img src="renders/sidebar-projects-by-host-dark.png" alt="Projects organized by host, including unreachable host in dark" width="232"> |
| Remote projects and host tags | <img src="renders/sidebar-projects-remote-light.png" alt="Remote projects and host tags in light" width="232"> | <img src="renders/sidebar-projects-remote-dark.png" alt="Remote projects and host tags in dark" width="232"> |
| Project folder-row states and accessories | <img src="renders/sidebar-project-rows-light.png" alt="Project folder-row states and accessories in light" width="460"> | <img src="renders/sidebar-project-rows-dark.png" alt="Project folder-row states and accessories in dark" width="460"> |
| Full native window with a live stub-pi turn | <img src="renders/app-window-light.png" alt="Full native window with a live stub-pi turn in light" width="460"> | <img src="renders/app-window-dark.png" alt="Full native window with a live stub-pi turn in dark" width="460"> |
| Minimum native window with automatically hidden sidebar | <img src="renders/app-window-minimum-light.png" alt="Minimum native window with automatically hidden sidebar in light" width="460"> | <img src="renders/app-window-minimum-dark.png" alt="Minimum native window with automatically hidden sidebar in dark" width="460"> |
| Native window header when the sidebar is hidden | <img src="renders/sidebar-hidden-header-light.png" alt="Native window header when the sidebar is hidden in light" width="460"> | <img src="renders/sidebar-hidden-header-dark.png" alt="Native window header when the sidebar is hidden in dark" width="460"> |

## Reproduce

```sh
swift test --filter 'ShepherdAppUnitTests.(Sidebar|Design|Pin)|ShepherdAppIntegrationTests.(Sidebar|WorkspaceNavigation|DesignFlow|DesignLifecycleFlow|ListPerformanceTests)|ShepherdUIUnitTests.DesignRules'
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-sidebar-pr-previews swift test --skip-build --filter 'PreviewTests.*(sidebar|appWindow\(surface)'
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile -derivedDataPath /tmp/shepherd-sidebar-pr-xcode build
python3 -m unittest discover -s Tests/Release -p 'test_agent_docs.py'
```
