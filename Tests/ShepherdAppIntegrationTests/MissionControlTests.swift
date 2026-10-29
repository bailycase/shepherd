import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Mission controls", .mainActorExclusive)
@MainActor
struct MissionControlTests {
    @Test func nativeControlsPlanLaunchReviewAndPublishTwoRepositories() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario {
                // Both appearances run the real journey, not a second view seeded with receipts.
                try await Self.journey(dark: false)
                try await Self.journey(dark: true)
            }
        }
        expectScenarioCompleted(result)
    }

    @Test func interruptedPlanningResumesPlanningWithoutAuthorizingWorkers() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.resumePlanning() }
        }
        expectScenarioCompleted(result)
    }

    private static func resumePlanning() async throws {
        AccessibilityNode.enable()
        let fixture = try MissionRuntimeFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let controller = try #require(fixture.controller)
        let draft = MissionDraft(title: "Interrupted planning", goal: "Update both result files.",
            plan: MissionPlan(lanes: fixture.spaces.map { .init(spaceID: $0.id, name: $0.name, baseBranch: "refs/heads/main") }))
        let mission = try await fixture.app.server.createMission(draft: draft)
        var run = MissionRun(model: MissionRuntimeFixture.model)
        run.transition(to: .paused, at: Date().timeIntervalSince1970, notice: "App stopped during planning.")
        _ = try await fixture.app.server.setMissionRun(id: mission.id, expectedRevision: mission.revision, run: run)
        controller.selectedID = mission.id
        try await fixture.wait(mission.id, phase: .paused)
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1100), dark: false,
                                     MissionsDestination(controller: controller))
        defer { window.close() }
        try await ready("Resume planning", in: window)
        var images: [String] = []
        try capture("planning-paused", dark: false, window: window, images: &images)
        try window.press("Resume planning")
        try await ready("Launch", in: window)
        try await fixture.wait(mission.id, phase: .map)
        let planned = try controller.record(mission.id)
        #expect(planned.approvedPlanRevision == nil)
        #expect(planned.run?.plannerID != nil)
        #expect(planned.run?.attempts.allSatisfy { $0.stationID == nil } == true)
        try fixture.expectUnpublished(mission.id)
    }

    private static func journey(dark: Bool) async throws {
        AccessibilityNode.enable()
        let fixture = try MissionRuntimeFixture()
        defer { fixture.stop() }
        try await fixture.start()
        try Data().write(to: fixture.root.appendingPathComponent("ask-clarification"))
        let controller = fixture.app.vm.missions
        #expect(controller === fixture.controller)
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1100), dark: dark,
                                     MissionsDestination(controller: fixture.app.vm.missions)
                                        .environment(\.colorScheme, dark ? .dark : .light))
        defer { window.close() }
        var images: [String] = []

        try await ready("New mission", in: window)
        try capture("list", dark: dark, window: window, images: &images)
        try window.press("New mission")
        try await ready("Plan the mission", enabled: false, in: window)
        try capture("start-empty", dark: dark, window: window, images: &images)

        let goal = "Change result.txt to after in both repositories and verify it independently."
        let setter = NSSelectorFromString("setAccessibilityValue:")
        let editor = try #require(AccessibilityNode.all(under: window.host).first {
            $0.label == "Mission goal" && $0.object.responds(to: setter)
        }, "The goal composer must expose a native editable accessibility value")
        _ = editor.object.perform(setter, with: goal)
        if let textView = editor.object as? NSTextView {
            // TextEditor sometimes exposes a setter without forwarding its binding change.
            // insertText uses the native editing pipeline, with no focus or OS input events.
            textView.insertText(goal, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView)
        }
        try await ready("Plan the mission", enabled: false, in: window)
        for space in fixture.spaces {
            try await ready(space.name, in: window)
            try window.press(space.name)
        }
        try await ready("Plan the mission", in: window)
        #expect(controller.availableModels.contains(MissionRuntimeFixture.model))
        for space in fixture.spaces {
            #expect(controller.defaultBranches[space.id] == "refs/heads/main")
            // A native menu button names itself by its tooltip.
            #expect(AccessibilityNode.all(under: window.host).contains { node in
                node.role == ControlRole.menuButton
                    && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == "\(space.name), starting branch main"
            }, "Default branch chip for \(space.name)")
        }
        try capture("start-ready", dark: dark, window: window, images: &images)
        try window.press("Plan the mission")
        try await eventuallyOnMain("the UI creates exactly one mission", timeout: .seconds(60)) {
            controller.records.count == 1
        }
        let id = try #require(controller.records.first?.id)
        try await eventuallyOnMain("planner clarification is shown", timeout: .seconds(60)) {
            controller.records.first?.run?.pendingQuestion != nil
        }
        // The question card waits for an answer; nothing offers Launch until the map is drafted.
        try await ready("Answer below", in: window)
        #expect(!window.controls().contains { $0.label == "Launch" })
        #expect(!accessibilityText(window).contains("{\"summary\""), "The conversation must not expose the planner's wire format")
        try capture("goal-question", dark: dark, window: window, images: &images)
        let reply = try #require(AccessibilityNode.all(under: window.host).first {
            $0.label == "Reply to the planner, or tell it what to change…" && $0.object.responds(to: setter)
        })
        let answer = "Yes. Both repositories must use exactly the same result format."
        _ = reply.object.perform(setter, with: answer)
        if let textView = reply.object as? NSTextView {
            textView.insertText(answer, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView)
        }
        try await ready("Send to the planner", in: window)
        try window.press("Send to the planner")
        try await ready("Launch", in: window)
        try await fixture.wait(id, phase: .map)
        let planned = try controller.record(id)
        #expect(planned.draft.goal == goal)
        #expect(Set(planned.draft.spaceIDs) == Set(fixture.spaces.map(\.id)))
        #expect(planned.draft.plan?.lanes.allSatisfy { $0.baseBranch == "refs/heads/main" } == true)
        #expect(planned.run?.model == MissionRuntimeFixture.model)
        #expect(planned.approvedPlanRevision == nil)
        for station in try #require(planned.draft.plan?.stations) {
            #expect(window.controls().contains { $0.label?.hasPrefix("\(station.title), ") == true && $0.label?.hasSuffix(", not started") == true },
                    "Map node for \(station.title): \(window.controls())")
        }
        try fixture.expectUnpublished(id)
        try capture("map", dark: dark, window: window, images: &images)
        try window.press("Launch")
        try await eventuallyOnMain("Launch leaves the unapproved map", timeout: .seconds(60)) {
            controller.records.first { $0.id == id }?.approvedPlanRevision != nil
                && controller.records.first { $0.id == id }?.run?.phase != .map
        }
        try capture("run", dark: dark, window: window, images: &images)
        try await fixture.wait(id, phase: .review)
        let publish = "Approve 2 PRs · publish"
        try await ready(publish, in: window)
        let reviewed = try controller.record(id)
        let run = try #require(reviewed.run)
        #expect(reviewed.approvedPlanRevision != nil)
        #expect(run.attempts.count == 8)
        for station in try #require(reviewed.draft.plan?.stations) {
            let attempt = try #require(run.latest(station.id))
            #expect(attempt.status == .succeeded)
            if station.kind == .check {
                #expect(attempt.exitCode == 0 && attempt.output.contains("HOST_CHECK_OK"))
            } else if station.kind == .validator {
                #expect(attempt.output.contains("Read actual result.txt") && !attempt.output.hasPrefix("{"))
            }
        }
        // Review collects its diffs on open, through the same refresh as the stale banner's control.
        try await eventuallyOnMain("review collected both repositories", timeout: .seconds(60)) { controller.reviews[id]?.count == 2 }
        try await ready(publish, in: window)
        // Open the requirement and the host check for their evidence.
        for prefix in ["1. ", "2. "] {
            let row = try #require(window.controls().first { $0.role == ControlRole.button && $0.label?.hasPrefix(prefix) == true },
                                   "Contract row \(prefix): \(window.controls())")
            try window.press(try #require(row.label))
            window.layout()
            if prefix == "1. " { #expect(accessibilityText(window).contains("Read actual result.txt")) }
        }
        try await eventuallyOnMain("rendered validation evidence and actual diff") {
            window.layout()
            let text = accessibilityText(window)
            return text.contains("HOST_CHECK_OK")
                && text.contains("before") && text.contains("after")
        }
        let files = window.controls().filter { $0.role == ControlRole.button && $0.label == "result.txt" }
        try #require(files.count == 2, "Review must offer both repository files: \(window.controls())")
        for index in files.indices {
            let label = try #require(files[index].label)
            let nth = files.prefix(index).filter { $0.label == label }.count
            try window.press(label, nth: nth)
            window.layout()
            try capture("review-repository-\(index + 1)", dark: dark, window: window, images: &images)
        }
        window.window.setContentSize(CGSize(width: AppLayout.mainColumnMinWidth, height: 900))
        window.layout()
        try capture("review-compact", dark: dark, window: window, images: &images)
        window.window.setContentSize(CGSize(width: 1440, height: 1100))
        window.layout()
        try fixture.expectUnpublished(id)
        let fingerprint = try #require(run.reviewFingerprint)
        // The current surface publishes directly; it draws no confirmation dialog. The resizes above
        // re-render the review, so wait for the control to be enabled again before pressing it.
        try await ready(publish, in: window)
        try window.press(publish)
        do {
            try await eventuallyOnMain("Publish authorizes the displayed receipt", timeout: .seconds(60)) {
                controller.records.first { $0.id == id }?.run?.publicationApproval == fingerprint
            }
        } catch {
            let current = try? controller.record(id)
            Issue.record("Publish did not authorize: error=\(controller.error ?? "nil") phase=\(current?.run?.phase.rawValue ?? "nil") notice=\(current?.run?.notice ?? "nil") publishEnabled=\(window.controls().first { $0.label == publish }?.isEnabled ?? false) revision=\(current?.revision ?? 0) reviewed=\(reviewed.revision)")
            throw error
        }
        try await fixture.wait(id, phase: .done)
        try capture("done-arrived", dark: dark, window: window, images: &images)
        try await eventuallyOnMain("Done renders both pull request links") {
            window.layout()
            return window.controls().filter { $0.label == "Open pull request" }.count == 2
                && accessibilityText(window).contains("Published in order")
        }
        let published = try #require(controller.record(id).run)
        #expect(published.publicationApproval == fingerprint)
        for checkout in published.checkouts {
            let index = try #require(fixture.spaces.firstIndex { $0.id == checkout.spaceID })
            let head = try #require(checkout.publishedHead)
            #expect(checkout.prURL == "https://github.invalid/fixture/repo/pull/1")
            let pushed = try git(["rev-parse", "refs/heads/" + checkout.branch], in: fixture.remotes[index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(pushed.hasPrefix(head))
            #expect(try git(["show", pushed + ":result.txt"], in: fixture.remotes[index]) == "after\n")
            #expect(try git(["rev-parse", pushed + "^"], in: fixture.remotes[index])
                .trimmingCharacters(in: .whitespacesAndNewlines) == fixture.initialHeads[index])
        }
        let gh = try String(contentsOf: fixture.ghLog, encoding: .utf8)
        #expect(gh.split(separator: "\n").filter { $0.hasPrefix("pr create ") }.count == 2)
        try fixture.expectSourcesUnchanged()
        #expect(fixture.app.vm.selectedAgentID == nil)
        #expect(!window.window.isKeyWindow && !window.window.isMainWindow)
        try capture("done", dark: dark, window: window, images: &images)
        if let directory = outputDirectory {
            let manifest: [String: Any] = ["mission": id.rawValue, "appearance": dark ? "dark" : "light",
                                           "images": images, "repositories": fixture.repos.map(\.path),
                                           "pullRequests": published.checkouts.compactMap(\.prURL),
                                           "originalRepositoriesUnchanged": true]
            let path = directory.appendingPathComponent("mission-controls-\(dark ? "dark" : "light")-manifest.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: path)
            print("Mission control manifest: \(path.path)")
        }
    }

    private static func ready(_ label: String, enabled: Bool = true, in window: OffscreenWindow) async throws {
        try await eventuallyOnMain("\(label) is rendered \(enabled ? "enabled" : "disabled")", timeout: .seconds(60)) {
            window.layout()
            return window.controls().contains { $0.label == label && $0.role == ControlRole.button && $0.isEnabled == enabled }
        }
    }

    private static func accessibilityText(_ window: OffscreenWindow) -> String {
        AccessibilityNode.all(under: window.host).flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
    }

    private static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func capture(_ state: String, dark: Bool, window: OffscreenWindow, images: inout [String]) throws {
        guard let directory = outputDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.layout()
        let bitmap = try #require(window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds))
        window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let name = "mission-controls-\(state)-\(dark ? "dark" : "light")"
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        try (window.controls().map(\.description).joined(separator: "\n") + "\n\n" + accessibilityText(window))
            .write(to: directory.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
        images.append(name + ".png")
    }
}
