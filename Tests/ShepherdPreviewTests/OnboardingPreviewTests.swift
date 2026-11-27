import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// First-run setup, one render per step (OnboardingWelcome, OnboardingImport, OnboardingSignIn, OnboardingSpace, OnboardingFleet,
/// OnboardingReady), light and dark, over the desktop the boards draw.
@Suite("Onboarding previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct OnboardingPreviewTests {
    @Test(arguments: OnboardingModel.Step.allCases)
    func step(_ step: OnboardingModel.Step) async throws {
        let world = try PreviewWorkspace()
        defer { world.stop() }
        let vm = world.vm
        let space = Space(name: "payments-api", path: world.dir.appendingPathComponent("payments-api").path)
        try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true)
        try await world.seed(ShepherdState(spaces: [space], tabs: [], agents: []))
        vm.yourPi.importSheet = PreviewYourPi.importDone
        let model = vm.onboarding
        model.hasPi = true
        let developer = ["payments-api", "dashboard-web", "shepherd"].enumerated().map { index, name in
            OnboardingScan.Candidate(path: "/Users/demo/Developer/\(name)", name: name, display: "~/Developer/\(name)", branch: index == 2 ? "nightly" : "main")
        }
        model.use(root: "~/Developer", candidates: developer)
        vm.fleet.found = [FoundMac(id: "mini", name: "Mac mini", version: "1.9"), FoundMac(id: "studio", name: "Mac Studio")]
        model.begin()
        while model.step < step { model.next() }
        if step == .ready { model.added(space.id) }
        try await Preview.render("onboarding-\(step)", size: CGSize(width: 1440, height: 900)) {
            OnboardingOverlay(vm: vm)
        }
    }
}
