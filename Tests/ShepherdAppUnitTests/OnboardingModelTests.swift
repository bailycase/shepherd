import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdApp

@Suite("Onboarding")
@MainActor
struct OnboardingModelTests {
    private func model(hasPi: Bool = false) throws -> (OnboardingModel, URL) {
        let dir = try makeScratchDirectory("onboarding")
        let model = OnboardingModel(marker: dir.appendingPathComponent("onboarding-finished"), home: dir)
        model.hasPi = hasPi
        return (model, dir)
    }

    private func repo(_ name: String, branch: String, in folder: URL) throws {
        let git = folder.appendingPathComponent(name).appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: git.appendingPathComponent("HEAD"))
    }

    @Test func theStepsSkipYourPiWhenThereIsNoPiToBringOver() throws {
        let (model, _) = try model()
        #expect(model.steps == [.welcome, .signIn, .space, .fleet, .ready])
        model.hasPi = true
        #expect(model.steps == OnboardingModel.Step.allCases)
    }

    @Test func nextAndBackWalkTheStepsAndNeverLeaveThem() throws {
        let (model, _) = try model()
        model.begin()
        model.next(); model.next()
        #expect(model.step == .space)
        model.back()
        #expect(model.step == .signIn)
        model.back(); model.back()
        #expect(model.step == .welcome)
        for _ in 0..<10 { model.next() }
        #expect(model.step == .ready)
    }

    @Test func aDotOnlyGoesBackToAStepAlreadyPassed() throws {
        let (model, _) = try model(hasPi: true)
        model.begin()
        model.next(); model.next()
        model.go(to: .fleet)
        #expect(model.step == .signIn)
        model.go(to: .welcome)
        #expect(model.step == .welcome)
    }

    @Test func finishingIsRememberedForThatFolderAlone() throws {
        let (model, dir) = try model()
        #expect(!model.finishedBefore)
        model.begin()
        model.finish()
        #expect(!model.isActive)
        #expect(model.finishedBefore)
        #expect(!OnboardingModel(marker: dir.appendingPathComponent("elsewhere"), home: dir).finishedBefore)
    }

    @Test func theScanFindsTheReposOfTheFirstUsualFolderThatHasAny() throws {
        let (_, home) = try model()
        let developer = home.appendingPathComponent("Developer")
        try repo("payments-api", branch: "main", in: developer)
        try repo("shepherd", branch: "nightly", in: developer)
        try FileManager.default.createDirectory(at: developer.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try repo("elsewhere", branch: "main", in: home.appendingPathComponent("code"))
        let found = OnboardingScan.find(in: home)
        #expect(found.root == "~/Developer")
        #expect(found.candidates.map(\.name) == ["payments-api", "shepherd"])
        #expect(found.candidates.map(\.branch) == ["main", "nightly"])
        #expect(found.candidates.first?.display == "~/Developer/payments-api")
    }

    @Test func aDetachedHeadShowsItsShortHashAndNoRepoMeansNoRoot() throws {
        let (_, home) = try model()
        #expect(OnboardingScan.find(in: home).root == nil)
        let git = home.appendingPathComponent("repo/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("0123456789abcdef\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        #expect(OnboardingScan.branch(of: home.appendingPathComponent("repo")) == "0123456")
    }

    @Test func aFolderChosenByHandJoinsTheListAndIsPicked() throws {
        let (model, home) = try model()
        let first = OnboardingScan.Candidate(path: "/a/one", name: "one", display: "/a/one", branch: "main")
        model.use(root: nil, candidates: [first])
        #expect(model.selection == "/a/one")
        model.choose(folder: home.appendingPathComponent("two").path)
        #expect(model.candidates.count == 2)
        #expect(model.selection == home.appendingPathComponent("two").path)
    }
}
