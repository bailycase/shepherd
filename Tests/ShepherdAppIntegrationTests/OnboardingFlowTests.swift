import AppKit
import Foundation
import ShepherdCore
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// First-run setup walked through its buttons, on a real host: Welcome, Sign in, A space (a repo found in the home folder is added), Your Macs,
/// and Ready, where Start thread asks for the thread in the space that was added.
@MainActor
@Suite("Onboarding flow", .mainActorExclusive)
struct OnboardingFlowTests {
    @Test func theButtonsWalkEveryStepAndTheLastStartsAThreadInTheSpaceAdded() async throws {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.walk() }
        }
    }

    private static func walk() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let home = app.dir.appendingPathComponent("home")
        let repo = home.appendingPathComponent("Developer/payments-api")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        let vm = try await app.start(welcomingYourPi: true)
        let model = vm.onboarding
        try? FileManager.default.removeItem(at: app.dir.appendingPathComponent("onboarding-finished"))
        await vm.beginOnboardingIfNeeded()
        try #require(model.isActive, "a first launch with no space starts setup")
        model.use(root: "~/Developer", candidates: [OnboardingScan.candidate(at: repo, home: home)])
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: false, RootView(vm: vm))
        defer { window.close() }
        func press(_ label: String) async throws {
            try await eventuallyOnMain("\(label) is there") { window.layout(); return window.controls().contains { $0.label == label && $0.isEnabled } }
            try window.press(label)
        }
        #expect(model.step == .welcome)
        try await press("Get started")
        try await eventuallyOnMain("the step after Welcome") { model.step != .welcome }
        // A pi of theirs, when there is one, is brought over first; Continue waits for the copy.
        if model.step == .pi {
            try await eventuallyOnMain("the copy to end") { vm.yourPi.importSheet?.stage != .progress }
            try await press("Continue")
        }
        try await eventuallyOnMain("Sign in") { model.step == .signIn }
        try await press("Continue")
        try await eventuallyOnMain("A space") { model.step == .space }
        try await press("Add space")
        try await eventuallyOnMain("the space is added and Your Macs shows") { model.step == .fleet && model.addedSpace != nil }
        #expect(vm.state.spaces.contains { $0.id == model.addedSpace }, "spaces: \(vm.state.spaces.map { "\($0.name) \($0.path)" }) added \(String(describing: model.addedSpace)) problem \(String(describing: model.problem))")
        try await press("Not now")
        try await eventuallyOnMain("Ready") { model.step == .ready }
        model.prompt = "Add retries with backoff"
        try await press("Start thread")
        try await eventuallyOnMain("setup is over") { !model.isActive && model.finishedBefore }
        // The thread is asked for in the space that was added, with the words typed: a host with no sign-in refuses it, so the draft stays.
        #expect(vm.newThread.place?.space == model.addedSpace)
        #expect(vm.newThread.prompt == "Add retries with backoff" || vm.state.agents.contains { $0.spaceID == model.addedSpace })
    }
}
